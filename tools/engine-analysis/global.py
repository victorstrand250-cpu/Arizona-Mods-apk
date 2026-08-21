"""Кто трогает конкретный глобал.

xref.py собирает пары ADRP+ADD и ADRP+LDR, но записи (str/strb/strh) и
загрузки чисел с плавающей точкой мимо него проходят. Здесь разбираются все
формы «база из ADRP плюс смещение», поэтому по адресу глобала видно и кто
его читает, и кто пишет, и какого он размера.

    python3 global.py libag-client.so 0x9948B0 [0x117E384 ...]
"""
import struct, sys, collections
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from xref import ELF, sign

# (маска, значение, множитель смещения, подпись)
FORMS = [
    (0xFFC00000, 0xF9400000, 8, 'ldr  x'),
    (0xFFC00000, 0xB9400000, 4, 'ldr  w'),
    (0xFFC00000, 0x79400000, 2, 'ldrh w'),
    (0xFFC00000, 0x39400000, 1, 'ldrb w'),
    (0xFFC00000, 0xBD400000, 4, 'ldr  s'),
    (0xFFC00000, 0xFD400000, 8, 'ldr  d'),
    (0xFFC00000, 0xF9000000, 8, 'str  x'),
    (0xFFC00000, 0xB9000000, 4, 'str  w'),
    (0xFFC00000, 0x79000000, 2, 'strh w'),
    (0xFFC00000, 0x39000000, 1, 'strb w'),
    (0xFFC00000, 0xBD000000, 4, 'str  s'),
    (0xFFC00000, 0xFD000000, 8, 'str  d'),
    (0xFFC00000, 0x91000000, 1, 'add  x'),   # взятие адреса
]


def decode(w):
    for mask, val, mult, name in FORMS:
        if (w & mask) == val:
            return name, w & 0x1F, (w >> 5) & 0x1F, ((w >> 10) & 0xFFF) * mult
    return None


def touches(so, targets):
    elf = ELF(so)
    t = elf.sec('.text')
    base, off, size = t['addr'], t['off'], t['size']
    n = size // 4
    words = struct.unpack_from('<%dI' % n, elf.data, off)

    pages = {addr & ~0xFFF for addr in targets}
    hits = collections.defaultdict(list)

    for i in range(n):
        w = words[i]
        if (w & 0x9F000000) != 0x90000000:      # ADRP
            continue
        rd = w & 0x1F
        immlo, immhi = (w >> 29) & 3, (w >> 5) & 0x7FFFF
        pc = base + i * 4
        page = (pc & ~0xFFF) + (sign((immhi << 2) | immlo, 21) << 12)
        if page not in pages:
            continue
        # Регистр живёт недолго: смотрим вперёд до его перезаписи.
        for j in range(i + 1, min(i + 12, n)):
            w2 = words[j]
            d = decode(w2)
            if d and d[2] == rd:
                name, _, _, imm = d
                addr = page + imm
                if addr in targets:
                    hits[addr].append((base + j * 4, name))
            if (w2 & 0x9F000000) == 0x90000000 and (w2 & 0x1F) == rd:
                break
    return hits


if __name__ == '__main__':
    so = sys.argv[1]
    targets = {int(a, 0) for a in sys.argv[2:]}
    hits = touches(so, targets)
    for addr in sorted(targets):
        lst = hits.get(addr, [])
        forms = collections.Counter(name for _, name in lst)
        print('0x%X — обращений %d: %s' % (
            addr, len(lst),
            ', '.join('%s x%d' % (k.strip(), v) for k, v in forms.most_common())))
        for pc, name in lst[:12]:
            print('    %-8s 0x%X' % (name.strip(), pc))
