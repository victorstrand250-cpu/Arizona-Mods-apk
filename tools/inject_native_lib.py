#!/usr/bin/env python3
"""
inject_native_lib.py — встраивание своей нативной библиотеки в APK Arizona Mobile.

Патчит ТОЛЬКО тот один classes*.dex, в котором лежит нужный класс, и пересобирает
zip, не трогая остальные записи. Это безопаснее полного круга apktool d/b:
ресурсы, resources.arsc и прочие dex остаются байт-в-байт исходными.

Что делает:
  1. находит classesN.dex с указанным классом;
  2. разбирает его baksmali;
  3. вставляет System.loadLibrary("<имя>") в НАЧАЛО <clinit> этого класса
     (если <clinit> нет — создаёт его);
  4. собирает dex обратно smali;
  5. кладёт .so в lib/<abi>/ и записывает новый APK.

Точка внедрения по умолчанию — com/arizonagames/client/game/core/JNILib.
Её <clinit> вызывает System.loadLibrary("ag-client"), то есть наша библиотека
грузится РАНЬШЕ движка и её JNI_OnLoad успевает поставить хуки до старта игры.
Для старого движка используйте --class com/arzmod/radare/InitGamePatch или
com/arizona/game/GTASAInternal.

Нужны smali.jar и baksmali.jar (2.5.x): https://bitbucket.org/JesusFreke/smali/downloads/

Пример:
    python3 tools/inject_native_lib.py \
        --apk ARIZONA.ONLINE_v17.7.1.apk \
        --out ARIZONA.ONLINE_v17.7.1_monet.apk \
        --lib arm64-v8a=libmonetloader.so \
        --lib arm64-v8a=libluajit-5.1.so \
        --load monetloader \
        --smali tools/smali.jar --baksmali tools/baksmali.jar

APK на выходе НЕ подписан. Подпишите его apksigner/uber-apk-signer или
просто откройте и сохраните в MT Manager — он подпишет сам.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

DEFAULT_CLASS = "com/arizonagames/client/game/core/JNILib"


# ---------------------------------------------------------------- dex helpers

def _uleb(d: bytes, o: int) -> tuple[int, int]:
    r = s = 0
    while True:
        b = d[o]
        o += 1
        r |= (b & 0x7F) << s
        s += 7
        if not b & 0x80:
            return r, o


def dex_strings(blob: bytes) -> set[str]:
    """Все строки из string_ids таблицы dex."""
    if blob[:4] != b"dex\n":
        return set()
    count, off = struct.unpack_from("<II", blob, 56)
    out = set()
    for i in range(count):
        so = struct.unpack_from("<I", blob, off + i * 4)[0]
        n, o2 = _uleb(blob, so)
        try:
            out.add(blob[o2:o2 + n * 4].split(b"\0")[0].decode("utf-8", "replace"))
        except Exception:  # noqa: BLE001
            pass
    return out


def find_dex_with_class(apk: str, cls: str) -> str:
    """Имя записи classesN.dex, в которой определён класс cls."""
    descriptor = f"L{cls};"
    with zipfile.ZipFile(apk) as z:
        names = [n for n in z.namelist()
                 if re.fullmatch(r"classes\d*\.dex", n)]
        names.sort(key=lambda n: (len(n), n))
        for n in names:
            if descriptor in dex_strings(z.read(n)):
                return n
    raise SystemExit(f"класс {cls} не найден ни в одном classes*.dex")


# -------------------------------------------------------------- smali surgery

CLINIT_RE = re.compile(r"^\.method\s+.*\bconstructor\s+<clinit>\(\)V\s*$")
REG_RE = re.compile(r"^\s*\.(registers|locals)\s+(\d+)\s*$")
SKIP_BLOCK = {".annotation": ".end annotation", ".param": ".end param"}

NEW_CLINIT = """.method static constructor <clinit>()V
    .registers 1

    const-string v0, "{name}"

    invoke-static {{v0}}, Ljava/lang/System;->loadLibrary(Ljava/lang/String;)V

    return-void
.end method
"""


def patch_smali(path: str, libname: str) -> None:
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")

    # уже пропатчен?
    joined = "\n".join(lines)
    if f'const-string v0, "{libname}"' in joined or \
       f'const-string/jumbo v0, "{libname}"' in joined:
        print(f"    [=] {libname}: уже присутствует, пропускаю")
        return

    start = next((i for i, l in enumerate(lines) if CLINIT_RE.match(l)), None)

    if start is None:
        # <clinit> нет — добавляем свой перед первым .method, иначе в конец
        ins = next((i for i, l in enumerate(lines)
                    if l.startswith(".method")), len(lines))
        lines[ins:ins] = NEW_CLINIT.format(name=libname).split("\n")
        print(f"    [+] {libname}: создан новый <clinit>")
    else:
        reg_i = next((i for i in range(start, len(lines)) if REG_RE.match(lines[i])),
                     None)
        if reg_i is None:
            raise SystemExit(f"в <clinit> ({path}) нет .registers/.locals")

        kind, count = REG_RE.match(lines[reg_i]).groups()
        count = int(count)
        # v<count> заведомо не используется существующим кодом метода
        free = count
        lines[reg_i] = f"    .{kind} {count + 1}"

        # ищем место сразу перед первой инструкцией
        i = reg_i + 1
        while i < len(lines):
            s = lines[i].strip()
            if not s or s.startswith("#"):
                i += 1
                continue
            head = s.split()[0]
            if head in SKIP_BLOCK:
                end = SKIP_BLOCK[head]
                while i < len(lines) and lines[i].strip() != end:
                    i += 1
                i += 1
                continue
            break

        op = "const-string/jumbo" if free > 15 else "const-string"
        lines[i:i] = [
            "",
            f"    {op} v{free}, \"{libname}\"",
            "",
            f"    invoke-static {{v{free}}}, "
            f"Ljava/lang/System;->loadLibrary(Ljava/lang/String;)V",
            "",
        ]
        print(f"    [+] {libname}: вставлено в <clinit>, "
              f"регистр v{free} (.{kind} {count} -> {count + 1})")

    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


# ------------------------------------------------------------------ zip align

def is_old_signature(name: str) -> bool:
    if not name.startswith("META-INF/"):
        return False
    up = name.upper()
    return up.endswith((".RSA", ".DSA", ".EC", ".SF")) or up.endswith("MANIFEST.MF")


def write_aligned(zf: zipfile.ZipFile, zi: zipfile.ZipInfo, data: bytes,
                  align: int = 4) -> None:
    """writestr + выравнивание данных STORED-записей (аналог zipalign).

    Начиная с targetSdk 30 Android требует, чтобы resources.arsc лежал
    несжатым И был выровнен на 4 байта, иначе установка падает с
    INSTALL_PARSE_FAILED_RESOURCES_ARSC_COMPRESSED / _NOT_ALIGNED.
    """
    if zi.compress_type == zipfile.ZIP_STORED:
        if zi.filename.endswith(".so"):
            align = 4096  # ровное выравнивание нативных библиотек
        offset = zf.fp.tell()
        head = offset + 30 + len(zi.filename.encode("utf-8")) + len(zi.extra)
        pad = (align - head % align) % align
        if pad:
            zi.extra = zi.extra + b"\x00" * pad
    zf.writestr(zi, data)


# ------------------------------------------------------------------- pipeline

def run(cmd: list[str]) -> None:
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.stderr.write(p.stdout + p.stderr)
        raise SystemExit(f"команда завершилась с ошибкой: {' '.join(cmd)}")


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apk", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--load", action="append", default=[], metavar="ИМЯ",
                    help="имя для System.loadLibrary (без lib/.so); можно несколько, "
                         "порядок сохраняется")
    ap.add_argument("--lib", action="append", default=[], metavar="ABI=ФАЙЛ",
                    help="положить файл в lib/<ABI>/; можно несколько")
    ap.add_argument("--class", dest="cls", default=DEFAULT_CLASS,
                    help=f"класс, в <clinit> которого внедряться (по умолчанию {DEFAULT_CLASS})")
    ap.add_argument("--smali", default="smali.jar")
    ap.add_argument("--baksmali", default="baksmali.jar")
    ap.add_argument("--api", type=int, default=29)
    ap.add_argument("--keep", action="store_true", help="не удалять временный каталог")
    args = ap.parse_args()

    if not args.load and not args.lib:
        ap.error("укажите хотя бы --load или --lib")
    for j in (args.smali, args.baksmali):
        if args.load and not os.path.isfile(j):
            ap.error(f"не найден {j} (нужен для правки dex)")

    tmp = tempfile.mkdtemp(prefix="inject_")
    try:
        patched_dex: dict[str, bytes] = {}

        if args.load:
            dex_name = find_dex_with_class(args.apk, args.cls)
            print(f"[*] класс {args.cls} найден в {dex_name}")

            dex_path = os.path.join(tmp, dex_name)
            with zipfile.ZipFile(args.apk) as z, open(dex_path, "wb") as f:
                f.write(z.read(dex_name))

            smali_dir = os.path.join(tmp, "smali")
            print("[*] baksmali ...")
            run(["java", "-jar", args.baksmali, "d", dex_path, "-o", smali_dir])

            target = os.path.join(smali_dir, args.cls + ".smali")
            if not os.path.isfile(target):
                raise SystemExit(f"нет файла {target}")

            print(f"[*] патчу {args.cls}.smali")
            # Каждая вставка идёт в самое начало <clinit>, поэтому проходим
            # список задом наперёд — тогда итоговый порядок вызовов
            # loadLibrary совпадает с порядком аргументов --load.
            for name in reversed(args.load):
                patch_smali(target, name)

            out_dex = os.path.join(tmp, "out.dex")
            print("[*] smali ...")
            run(["java", "-jar", args.smali, "a", smali_dir,
                 "-o", out_dex, "-a", str(args.api)])
            with open(out_dex, "rb") as f:
                patched_dex[dex_name] = f.read()
            print(f"[*] {dex_name}: {os.path.getsize(dex_path):,} -> "
                  f"{len(patched_dex[dex_name]):,} байт")

        extra: dict[str, bytes] = {}
        for spec in args.lib:
            if "=" not in spec:
                ap.error(f"--lib ждёт ABI=ФАЙЛ, получено {spec!r}")
            abi, path = spec.split("=", 1)
            with open(path, "rb") as f:
                extra[f"lib/{abi}/{os.path.basename(path)}"] = f.read()
            print(f"[*] в APK будет добавлено lib/{abi}/{os.path.basename(path)} "
                  f"({os.path.getsize(path):,} байт)")

        print(f"[*] пишу {args.out}")
        with zipfile.ZipFile(args.apk) as zin, \
                zipfile.ZipFile(args.out, "w", zipfile.ZIP_DEFLATED) as zout:
            for item in zin.infolist():
                if is_old_signature(item.filename):
                    continue  # старая подпись всё равно недействительна
                data = patched_dex.get(item.filename) or extra.pop(item.filename, None) \
                    or zin.read(item.filename)
                zi = zipfile.ZipInfo(item.filename, date_time=item.date_time)
                zi.compress_type = item.compress_type
                zi.external_attr = item.external_attr
                write_aligned(zout, zi, data)
            for name, data in extra.items():
                zi = zipfile.ZipInfo(name)
                zi.compress_type = zipfile.ZIP_DEFLATED
                write_aligned(zout, zi, data)

        print(f"[+] готово: {args.out} ({os.path.getsize(args.out):,} байт)")
        print("[!] APK НЕ подписан. Подпишите apksigner / uber-apk-signer,")
        print("    либо откройте и сохраните в MT Manager.")
        return 0
    finally:
        if args.keep:
            print(f"[*] временный каталог: {tmp}")
        else:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
