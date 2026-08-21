"""Кто зовёт glBufferSubData/glUniformMatrix4fv и какой глобал туда уходит.

librw заливает матрицы вида и проекции одним блоком: у него глобальная
структура UniformScene { float proj[16]; float view[16]; }, и её адрес
передаётся четвёртым аргументом. Значит достаточно найти вызов и отмотать,
чем заполнили x3.
"""
import struct, sys
sys.path.insert(0, '/tmp/claude-0/-home-user-Arizona-Mods-apk/6ea72e86-5e6b-5f93-ab8e-1ed9cecf90ac/scratchpad')
from xref import ELF, sign
from plt import stub_to_name

SO = '/tmp/claude-0/-home-user-Arizona-Mods-apk/6ea72e86-5e6b-5f93-ab8e-1ed9cecf90ac/scratchpad/work/new_x/lib/arm64-v8a/libag-client.so'
elf = ELF(SO)
t = elf.sec('.text')
base, off, size = t['addr'], t['off'], t['size']
n = size // 4
words = struct.unpack_from('<%dI' % n, elf.data, off)

def resolve_reg(i, reg, depth=30):
    """Чем заполнили регистр перед инструкцией i: adrp(+add) -> адрес."""
    add_imm = None
    want = reg
    for j in range(i - 1, max(0, i - depth), -1):
        w = words[j]
        if (w & 0xFFC00000) == 0x91000000 and (w & 0x1F) == want and add_imm is None:
            add_imm = (w >> 10) & 0xFFF
            want = (w >> 5) & 0x1F
            continue
        if (w & 0x9F000000) == 0x90000000 and (w & 0x1F) == want:
            immlo = (w >> 29) & 3
            immhi = (w >> 5) & 0x7FFFF
            page = ((base + j * 4) & ~0xFFF) + (sign((immhi << 2) | immlo, 21) << 12)
            return page + (add_imm or 0)
        # регистр перезаписан чем-то другим — дальше смысла нет
        if (w & 0x7FE0FC00) == 0x2A0003E0 and (w & 0x1F) == want:
            return None
    return None

targets = {}
for va, nm in stub_to_name.items():
    if nm in ('glBufferSubData', 'glUniformMatrix4fv'):
        targets[va] = nm

hits = {}
for i in range(n):
    w = words[i]
    if (w & 0xFC000000) != 0x94000000:
        continue
    dst = base + i * 4 + sign(w & 0x3FFFFFF, 26) * 4
    nm = targets.get(dst)
    if not nm:
        continue
    ptr = resolve_reg(i, 3)          # четвёртый аргумент
    if ptr is None:
        continue
    sec = elf.sec_of(ptr)
    if sec not in ('.bss', '.data'):
        continue
    hits.setdefault((nm, ptr, sec), []).append(base + i * 4)

print('глобалы, уходящие в GL четвёртым аргументом:\n')
for (nm, ptr, sec), sites in sorted(hits.items(), key=lambda x: -len(x[1])):
    print('  %-20s 0x%-10X %-6s вызовов: %d   (%s)' %
          (nm, ptr, sec, len(sites), ', '.join('0x%X' % s for s in sites[:3])))
