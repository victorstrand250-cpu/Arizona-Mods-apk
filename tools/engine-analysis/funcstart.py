"""Начало функции, в которую попадает адрес.

Декомпилятору нужно скармливать начало функции, а в stripped-библиотеке
границы никто не размечал. Пролог у arm64 узнаваемый: сохранение пары
x29/x30 с уменьшением sp, либо просто уменьшение sp, и перед ним —
конец предыдущей функции (ret, безусловный переход или мусор-выравнивание).

    python3 funcstart.py libag-client.so 0x7a4acc [0x...]
"""
import struct, sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from xref import ELF


def is_prologue(w):
    # stp x29, x30, [sp, #-imm]!   (pre-index)
    if (w & 0xFFC07FFF) == 0xA9807BFD:
        return True
    # sub sp, sp, #imm
    if (w & 0xFFC003FF) == 0xD10003FF:
        return True
    # stp xN, xM, [sp, #-imm]!  — тоже начало кадра
    if (w & 0xFFC003E0) == 0xA98003E0:
        return True
    return False


def is_end(w):
    if w == 0xD65F03C0:        # ret
        return True
    if (w & 0xFC000000) == 0x14000000:   # b
        return True
    if w == 0x00000000 or w == 0xD503201F:  # мусор или nop-выравнивание
        return True
    if (w & 0xFFE0001F) == 0xD4200000:   # brk
        return True
    return False


def find(elf, addr, limit=60000):
    t = elf.sec('.text')
    base, off, size = t['addr'], t['off'], t['size']
    n = size // 4
    words = struct.unpack_from('<%dI' % n, elf.data, off)
    i = (addr - base) // 4
    for k in range(i, max(0, i - limit), -1):
        if is_prologue(words[k]) and (k == 0 or is_end(words[k - 1])):
            return base + k * 4
    return None


if __name__ == '__main__':
    elf = ELF(sys.argv[1])
    for a in sys.argv[2:]:
        addr = int(a, 0)
        st = find(elf, addr)
        print('0x%X -> начало 0x%X' % (addr, st) if st
              else '0x%X -> начало не найдено' % addr)
