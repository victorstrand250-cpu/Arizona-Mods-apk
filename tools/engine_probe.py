#!/usr/bin/env python3
"""
engine_probe.py — разбор нативного движка Arizona Mobile и проверка того,
насколько он пригоден для MonetLoader.

Скрипт не требует NDK/objdump/radare — только Python 3.

Что делает:
  * парсит ELF (.dynsym/.symtab) и печатает статистику по экспортам;
  * проверяет наличие ВСЕХ символов libGTASA.so, которые MonetLoader
    резолвит через dlsym()/plt_scanner (см. MonetLoaderOSS cpp/main.cpp);
  * определяет, из чего собран движок (librw / boost.asio / RakNet / LuaJIT ...);
  * выводит JNI-функции (Java_*), по которым видно Java-слой движка.

Примеры:
    python3 tools/engine_probe.py lib/arm64-v8a/libGTASA.so
    python3 tools/engine_probe.py new_apk/lib/arm64-v8a/libag-client.so --json out.json
    python3 tools/engine_probe.py --apk ARIZONA.ONLINE_v17.7.1.apk
"""
from __future__ import annotations

import argparse
import json
import os
import re
import struct
import sys
import tempfile
import zipfile

# Символы libGTASA.so, без которых MonetLoader не может инициализироваться.
# Источник: MonetLoaderOSS/cpp/main.cpp -> do_init().
REQUIRED_SYMBOLS = {
    "hooks": [
        "_ZN5CGame7ProcessEv",
        "_ZN11CTheScripts4InitEv",
        "_ZN11CTheScripts7ProcessEv",
        "_ZN5CGame8ShutdownEv",
        "_ZN4CHID15FlushQueuedTextEv",
        "_Z24_rwOpenGLCameraEndUpdatePvS_i",
        "_ZN14CRunningScript7ProcessEv",
        "_ZN6CWorld3AddEP7CEntity",
        "_ZN6CWorld6RemoveEP7CEntity",
        "_Z14AND_TouchEventiiii",
    ],
    "common": [
        "_ZN14CRunningScript17ProcessOneCommandEv",
        "_ZN15CTouchInterface9IsTouchedENS_9WidgetIDsEP9CVector2Di",
        "_Z14AsciiToGxtCharPKcPt",
        "_Z14GxtCharToAsciiPth",
        "_ZN9CMessages13AddBigMessageEPtjt",
        "_ZN9CMessages10AddMessageEPKcPtjtb",
        "_ZN9CMessages15AddMessageJumpQEPKcPtjtb",
        "_ZN6CWorld18ProcessLineOfSightERK7CVectorS2_R9CColPointRP7CEntitybbbbbbbb",
        "_ZN7CSprite15CalcScreenCoorsERK5RwV3dPS0_PfS4_bb",
    ],
    "render": [
        "_ZN7CWidget10SetScissorER5CRect",
        "_Z16RwRenderStateGet13RwRenderStatePv",
        "_Z16RwRenderStateSet13RwRenderStatePv",
        "_Z35RwIm2DRenderIndexedPrimitive_BUGFIX15RwPrimitiveTypeP14RwOpenGLVertexiPti",
        "_Z20RwIm2DGetNearScreenZv",
        "_Z15RwRasterDestroyP8RwRaster",
        "_Z14RwRasterCreateiiii",
        "_Z20RwRasterSetFromImageP8RwRasterP7RwImage",
        "_Z12RwRasterLockP8RwRasterhi",
        "_Z14RwRasterUnlockP8RwRaster",
        "_Z13RwImageCreateiii",
        "_Z21RwImageAllocatePixelsP7RwImage",
        "_Z23RwImageFindRasterFormatP7RwImageiPiS1_S1_S1_",
        "_Z14RwImageDestroyP7RwImage",
        "_Z14RtPNGImageReadPKc",
    ],
    "globals": [
        "_ZN6CPools11ms_pPedPoolE",
        "_ZN6CPools15ms_pVehiclePoolE",
        "_ZN6CPools14ms_pObjectPoolE",
        "_ZN6CRadar13ms_RadarTraceE",
        "gMobileMenu",
        "_ZN6CTimer11m_UserPauseE",
        "_ZN6CTimer11m_CodePauseE",
        "RsGlobal",
        "TheText",
        "TheCamera",
        "_ZN9CSprite2d13RecipNearClipE",
        "Pads",
    ],
}

# Маркеры «из чего собран движок».
FINGERPRINTS = {
    "librw (open-source RenderWare)": [b"/librw/src/"],
    "RenderWare (Rockstar/Criterion)": [b"_Z24_rwOpenGLCameraEndUpdatePvS_i"],
    "boost.asio": [b"boost/asio/detail/impl/epoll_reactor.ipp"],
    "RakNet": [b"RakPeer", b"RakClientInterface", b"UNCONNECTED_PONG"],
    "LuaJIT": [b"luaJIT_", b"LuaJIT "],
    "MonetLoader": [b"monetloader", b"MonetLoader"],
    "spdlog": [b"N6spdlog"],
    "EASTL": [b"eastl"],
    "tinyxml2": [b"tinyxml2"],
    "FreeType": [b"FT_Init_FreeType"],
    "OpenAL Soft (встроен)": [b"ALC_SOFT_loopback"],
    "mpg123": [b"libmpg123"],
    "opus": [b"opus_decoder.c"],
    "nlohmann/json": [b"N8nlohmann"],
}


def _u(fmt, data, off):
    return struct.unpack_from(fmt, data, off)


def parse_elf(data: bytes) -> dict:
    if data[:4] != b"\x7fELF":
        raise ValueError("не ELF-файл")
    is64 = data[4] == 2
    if not is64:
        raise ValueError("поддерживается только ELF64 (arm64-v8a)")

    e_shoff = _u("<Q", data, 0x28)[0]
    e_shentsize = _u("<H", data, 0x3A)[0]
    e_shnum = _u("<H", data, 0x3C)[0]
    e_shstrndx = _u("<H", data, 0x3E)[0]

    secs = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        name, typ, flags, addr, off, size, link, info, align, entsize = _u(
            "<IIQQQQIIQQ", data, o
        )
        secs.append(
            dict(name=name, type=typ, addr=addr, off=off, size=size, link=link)
        )

    shstr = secs[e_shstrndx]
    strtab = data[shstr["off"]: shstr["off"] + shstr["size"]]

    def cstr(tab: bytes, x: int) -> str:
        end = tab.index(b"\0", x)
        return tab[x:end].decode("utf-8", "replace")

    for s in secs:
        s["sname"] = cstr(strtab, s["name"])

    result = {"sections": {s["sname"]: s["size"] for s in secs}, "symbols": {}}
    for s in secs:
        if s["sname"] not in (".dynsym", ".symtab"):
            continue
        st = secs[s["link"]]
        stab = data[st["off"]: st["off"] + st["size"]]
        defined, undefined = set(), set()
        for i in range(s["size"] // 24):
            o = s["off"] + i * 24
            nameo, info, other, shndx, val, sz = _u("<IBBHQQ", data, o)
            if not nameo:
                continue
            nm = cstr(stab, nameo)
            (undefined if shndx == 0 else defined).add(nm)
        result["symbols"][s["sname"]] = {"defined": defined, "undefined": undefined}
    return result


def fingerprint(data: bytes) -> list[str]:
    found = []
    for label, needles in FINGERPRINTS.items():
        if any(n in data for n in needles):
            found.append(label)
    return found


def jni_exports(defined: set[str]) -> list[str]:
    return sorted(s for s in defined if s.startswith("Java_"))


def analyse(path: str) -> dict:
    with open(path, "rb") as f:
        data = f.read()

    elf = parse_elf(data)
    dyn = elf["symbols"].get(".dynsym", {"defined": set(), "undefined": set()})
    sym = elf["symbols"].get(".symtab", {"defined": set(), "undefined": set()})
    defined = dyn["defined"] | sym["defined"]

    report = {
        "file": path,
        "size": len(data),
        "stripped": ".symtab" not in elf["symbols"],
        "dynsym_defined": len(dyn["defined"]),
        "dynsym_undefined": len(dyn["undefined"]),
        "bss_size": elf["sections"].get(".bss", 0),
        "text_size": elf["sections"].get(".text", 0),
        "built_from": fingerprint(data),
        "jni_exports": jni_exports(defined),
        "monetloader": {},
    }

    total = hit = 0
    for group, names in REQUIRED_SYMBOLS.items():
        present = sorted(n for n in names if n in defined)
        missing = sorted(n for n in names if n not in defined)
        total += len(names)
        hit += len(present)
        report["monetloader"][group] = {
            "present": present,
            "missing": missing,
            "score": f"{len(present)}/{len(names)}",
        }
    report["monetloader"]["total_score"] = f"{hit}/{total}"
    report["monetloader"]["usable"] = hit == total
    return report


def print_report(r: dict) -> None:
    print(f"=== {r['file']}")
    print(f"    размер:            {r['size']:,} байт")
    print(f"    .text / .bss:      {r['text_size']:,} / {r['bss_size']:,}")
    print(f"    .symtab отсутств.: {r['stripped']} (stripped)")
    print(f"    .dynsym:           {r['dynsym_defined']} определённых, "
          f"{r['dynsym_undefined']} внешних")
    print(f"    собран из:         {', '.join(r['built_from']) or '—'}")
    print()
    print("    Символы, которые MonetLoader резолвит в libGTASA.so:")
    for group in ("hooks", "common", "render", "globals"):
        g = r["monetloader"][group]
        print(f"      {group:<8} {g['score']}")
        for m in g["missing"][:6]:
            print(f"                 отсутствует: {m}")
        if len(g["missing"]) > 6:
            print(f"                 ... и ещё {len(g['missing']) - 6}")
    print(f"    ИТОГО: {r['monetloader']['total_score']} — "
          f"{'движок подходит' if r['monetloader']['usable'] else 'MonetLoader НЕ заработает как есть'}")
    print()
    if r["jni_exports"]:
        print(f"    JNI-экспорты ({len(r['jni_exports'])}):")
        classes = sorted({s.rsplit("_", 1)[0] for s in r["jni_exports"]})
        for c in classes[:20]:
            print(f"      {c}_*")
    print()


def libs_from_apk(apk: str) -> list[tuple[str, bytes]]:
    out = []
    with zipfile.ZipFile(apk) as z:
        for n in z.namelist():
            if n.startswith("lib/arm64-v8a/") and n.endswith(".so"):
                out.append((n, z.read(n)))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("so", nargs="*", help="путь(и) к .so")
    ap.add_argument("--apk", help="разобрать все lib/arm64-v8a/*.so внутри APK")
    ap.add_argument("--json", help="сохранить отчёт в JSON")
    args = ap.parse_args()

    reports = []
    targets: list[str] = list(args.so)
    tmpdir = None

    if args.apk:
        tmpdir = tempfile.mkdtemp(prefix="engine_probe_")
        for name, blob in libs_from_apk(args.apk):
            p = os.path.join(tmpdir, os.path.basename(name))
            with open(p, "wb") as f:
                f.write(blob)
            targets.append(p)

    if not targets:
        ap.error("укажите .so или --apk")

    for t in targets:
        try:
            r = analyse(t)
        except Exception as exc:  # noqa: BLE001
            print(f"=== {t}\n    пропущен: {exc}\n")
            continue
        reports.append(r)
        print_report(r)

    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(reports, f, ensure_ascii=False, indent=2)
        print(f"JSON-отчёт: {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
