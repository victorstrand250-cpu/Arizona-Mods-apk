"""Пулы за указателем: глобал хранит не сам массив, а указатель на него.

Массив игроков лежит в .bss целиком, а вот сущности мира движок держит
иначе: в .bss лежит указатель, а сам массив выделен в куче. В коде это
выглядит так:

    adrp x8, 0x315a000
    ldr  x8, [x8, #3608]       ; x8 = сам массив
    ldrh w9, [x22, #172]       ; индекс
    cmp  w9, #0x7cf            ; предел
    ldr  x10, [x8, x9, lsl #3] ; сущность
    ldr  d0, [x10, #56]        ; позиция

Здесь перебираются все такие места: адрес глобала-указателя, предел индекса
рядом и смещения, с которыми потом работают с сущностью.

    python3 pool3.py libag-client.so
"""
import struct, sys, collections
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from xref import ELF, sign

LOADS = [
    (0xFFC00000, 0xF9400000, 8, 'ldr  x'), (0xFFC00000, 0xB9400000, 4, 'ldr  w'),
    (0xFFC00000, 0x79400000, 2, 'ldrh w'), (0xFFC00000, 0x39400000, 1, 'ldrb w'),
    (0xFFC00000, 0xBD400000, 4, 'ldr  s'), (0xFFC00000, 0xFD400000, 8, 'ldr  d'),
]


def decode(w):
    for mask, val, mult, name in LOADS:
        if (w & mask) == val:
            return name, w & 0x1F, (w >> 5) & 0x1F, ((w >> 10) & 0xFFF) * mult
    return None


def main(so):
    elf = ELF(so)
    t = elf.sec('.text')
    base, off, size = t['addr'], t['off'], t['size']
    n = size // 4
    words = struct.unpack_from('<%dI' % n, elf.data, off)

    pools = collections.defaultdict(lambda: {'hits': 0, 'limits': collections.Counter(),
                                             'fields': collections.Counter(),
                                             'where': []})

    for i in range(n):
        w = words[i]
        # ldr xR, [xБаза, xИндекс, lsl #3]
        if (w & 0xFFE0FC00) != 0xF8607800:
            continue
        arr_reg = (w >> 5) & 0x1F
        obj_reg = w & 0x1F

        # Назад: ldr xArr, [xN, #imm] сразу после adrp xN, страница
        src = None
        for m in range(i - 1, max(0, i - 30), -1):
            w2 = words[m]
            if (w2 & 0xFFC00000) == 0xF9400000 and (w2 & 0x1F) == arr_reg:
                holder = (w2 >> 5) & 0x1F
                imm = ((w2 >> 10) & 0xFFF) * 8
                for k in range(m - 1, max(0, m - 12), -1):
                    w3 = words[k]
                    if (w3 & 0x9F000000) == 0x90000000 and (w3 & 0x1F) == holder:
                        immlo, immhi = (w3 >> 29) & 3, (w3 >> 5) & 0x7FFFF
                        page = ((base + k * 4) & ~0xFFF) + \
                               (sign((immhi << 2) | immlo, 21) << 12)
                        src = page + imm
                        break
                break
            if (w2 & 0x9F000000) == 0x90000000 and (w2 & 0x1F) == arr_reg:
                break
        if src is None:
            continue

        p = pools[src]
        p['hits'] += 1
        if len(p['where']) < 6:
            p['where'].append(base + i * 4)

        # Предел индекса: cmp wX, #imm неподалёку до загрузки.
        for m in range(max(0, i - 12), i):
            w2 = words[m]
            if (w2 & 0xFFC00000) == 0x7100_0000:      # cmp (subs wzr, wN, #imm)
                if (w2 & 0x1F) == 31:
                    p['limits'][((w2 >> 10) & 0xFFF) + 1] += 1

        # Поля сущности.
        for j in range(i + 1, min(i + 24, n)):
            d = decode(words[j])
            if d and d[2] == obj_reg:
                p['fields'][d[3]] += 1
            if d and d[1] == obj_reg:
                break

    rows = sorted(pools.items(), key=lambda kv: -kv[1]['hits'])
    print('%-14s %6s %10s  %s' % ('глобал', 'раз', 'предел', 'поля'))
    for addr, p in rows[:25]:
        lim = ', '.join('%d' % l for l, _ in p['limits'].most_common(2)) or '?'
        fields = ', '.join('+%d x%d' % (o, c) for o, c in p['fields'].most_common(7))
        print('0x%-12X %6d %10s  %s' % (addr, p['hits'], lim, fields))
        print('%15s код: %s' % ('', ', '.join('0x%X' % a for a in p['where'])))


if __name__ == '__main__':
    main(sys.argv[1])
