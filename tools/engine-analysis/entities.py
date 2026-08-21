"""Какие глобальные массивы указателей хранят сущности мира.

У сущности движка на +8 лежит матрица положения — четыре вектора по три
числа с выравниванием в 16 байт: направо +8, вверх +24, вперёд +40 и сама
позиция +56. Это отпечаток, по которому сущность отличается от чего угодно
другого: массив описаний моделей, например, читают по +29 и +44, а по +56
не читают никогда.

Поэтому перебираются все массивы вида `ldr xR, [xБаза, xИндекс, lsl #3]`,
и для каждого считается, с какими смещениями потом работают с полученным
указателем. Массив, у которого в лидерах +56, и есть пул сущностей.

    python3 entities.py libag-client.so
"""
import struct, sys, collections
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from xref import ELF, sign

LOADS = [
    (0xFFC00000, 0xF9400000, 8, 'ldr  x'), (0xFFC00000, 0xB9400000, 4, 'ldr  w'),
    (0xFFC00000, 0x79400000, 2, 'ldrh w'), (0xFFC00000, 0x39400000, 1, 'ldrb w'),
    (0xFFC00000, 0xBD400000, 4, 'ldr  s'), (0xFFC00000, 0xFD400000, 8, 'ldr  d'),
    (0xFFC00000, 0xF9000000, 8, 'str  x'), (0xFFC00000, 0xB9000000, 4, 'str  w'),
    (0xFFC00000, 0x39000000, 1, 'strb w'), (0xFFC00000, 0xBD000000, 4, 'str  s'),
]

# Смещения матрицы положения: по ним сущность и опознаётся.
MATRIX = (8, 24, 40, 56)


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

    # 1. Все места вида ldr xR, [xБаза, xИндекс, lsl #3], где база пришла
    #    из ADRP(+ADD) — то есть индексируют глобальный массив указателей.
    anchors = collections.defaultdict(list)   # адрес массива -> [(i, регистр)]
    for i in range(n):
        w = words[i]
        if (w & 0xFFE0FC00) != 0xF8607800:
            continue
        arr_reg = (w >> 5) & 0x1F
        add_imm = None
        for m in range(i - 1, max(0, i - 24), -1):
            w4 = words[m]
            if (w4 & 0xFFC00000) == 0x91000000 and (w4 & 0x1F) == arr_reg \
               and add_imm is None:
                add_imm = (w4 >> 10) & 0xFFF
                arr_reg = (w4 >> 5) & 0x1F
                continue
            if (w4 & 0x9F000000) == 0x90000000 and (w4 & 0x1F) == arr_reg:
                immlo, immhi = (w4 >> 29) & 3, (w4 >> 5) & 0x7FFFF
                page = ((base + m * 4) & ~0xFFF) + \
                       (sign((immhi << 2) | immlo, 21) << 12)
                anchors[page + (add_imm or 0)].append((i, w & 0x1F))
                break

    # 2. Для каждого массива — карта смещений, с которыми работают с
    #    вынутым указателем.
    rows = []
    for arr, places in anchors.items():
        if len(places) < 4:
            continue
        fields = collections.Counter()
        for idx, reg in places:
            for j in range(idx + 1, min(idx + 40, n)):
                w = words[j]
                d = decode(w)
                if d and d[2] == reg:
                    fields[d[3]] += 1
                # регистр перезаписан — дальше не наш указатель
                if d and d[1] == reg and d[0].startswith('ldr'):
                    break
        score = sum(fields[o] for o in MATRIX)
        rows.append((score, len(places), arr, fields))

    rows.sort(reverse=True)
    print('массивов указателей: %d\n' % len(rows))
    print('%-14s %8s %8s  %s' % ('адрес', 'обращ.', 'матрица', 'частые поля'))
    for score, cnt, arr, fields in rows[:20]:
        top = ', '.join('+%d x%d' % (o, c) for o, c in fields.most_common(8))
        print('0x%-12X %8d %8d  %s' % (arr, cnt, score, top))


if __name__ == '__main__':
    main(sys.argv[1])
