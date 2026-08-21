"""Ищет вызовы ImGui::Begin и восстанавливает заголовок окна и флаг-включатель.

Приём простой: находим все bl на нужный адрес, отматываем назад по инструкциям
и ищем, чем в последний раз заполнили x0 (заголовок) и x1 (указатель p_open).
"""
import struct, sys
sys.path.insert(0, '/tmp/claude-0/-home-user-Arizona-Mods-apk/6ea72e86-5e6b-5f93-ab8e-1ed9cecf90ac/scratchpad')
from xref import ELF, sign

SO = '/tmp/claude-0/-home-user-Arizona-Mods-apk/6ea72e86-5e6b-5f93-ab8e-1ed9cecf90ac/scratchpad/work/new_x/lib/arm64-v8a/libag-client.so'
BEGIN = int(sys.argv[1], 16) if len(sys.argv) > 1 else 0x8dee00

elf = ELF(SO)
t = elf.sec('.text')
base, off, size = t['addr'], t['off'], t['size']
n = size // 4
words = struct.unpack_from('<%dI' % n, elf.data, off)

def cstr(va):
    o = elf.va_to_off(va)
    if o is None:
        return None
    end = elf.data.index(b'\0', o)
    if end - o > 90:
        return None
    try:
        return elf.data[o:end].decode('utf-8')
    except UnicodeDecodeError:
        return None

def resolve_reg(i, reg, depth=40):
    """Идём назад от инструкции i, ищем чем заполнили reg (adrp+add)."""
    add_imm = None
    want = reg
    for j in range(i - 1, max(0, i - depth), -1):
        w = words[j]
        # ADD Rd, Rn, #imm
        if (w & 0xFFC00000) == 0x91000000 and (w & 0x1F) == want and add_imm is None:
            add_imm = (w >> 10) & 0xFFF
            want = (w >> 5) & 0x1F
            continue
        # ADRP Rd, page
        if (w & 0x9F000000) == 0x90000000 and (w & 0x1F) == want:
            immlo = (w >> 29) & 3
            immhi = (w >> 5) & 0x7FFFF
            imm = sign((immhi << 2) | immlo, 21) << 12
            page = ((base + j * 4) & ~0xFFF) + imm
            return page + (add_imm or 0)
    return None

found = []
for i in range(n):
    w = words[i]
    if (w & 0xFC000000) != 0x94000000:      # BL
        continue
    imm26 = sign(w & 0x3FFFFFF, 26) * 4
    if base + i * 4 + imm26 != BEGIN:
        continue
    title_va = resolve_reg(i, 0)
    open_va = resolve_reg(i, 1)
    title = cstr(title_va) if title_va else None
    if title:
        found.append((base + i * 4, title, open_va))

print('вызовов ImGui::Begin с распознанным заголовком: %d\n' % len(found))
for va, title, open_va in sorted(found, key=lambda x: x[1].lower()):
    flag = ''
    if open_va:
        sec = elf.sec_of(open_va)
        if sec in ('.bss', '.data'):
            flag = '  флаг 0x%X (%s)' % (open_va, sec)
    print('  %-38r код 0x%X%s' % (title, va, flag))
