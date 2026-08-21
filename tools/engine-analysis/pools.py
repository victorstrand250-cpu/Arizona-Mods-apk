"""Поиск пулов: глобальный массив, к которому обращаются по индексу.

Массив игроков нашёлся как «adrp+add на базу, индекс умножить на 336,
прочитать указатель». Тем же узором должны обнаружиться и остальные пулы
движка — транспорт, объекты, пешеходы.
"""
import struct, sys, collections
sys.path.insert(0, '/tmp/claude-0/-home-user-Arizona-Mods-apk/6ea72e86-5e6b-5f93-ab8e-1ed9cecf90ac/scratchpad')
from xref import ELF, sign

SO = '/tmp/claude-0/-home-user-Arizona-Mods-apk/6ea72e86-5e6b-5f93-ab8e-1ed9cecf90ac/scratchpad/work/new_x/lib/arm64-v8a/libag-client.so'
elf = ELF(SO)
t = elf.sec('.text')
base, off, size = t['addr'], t['off'], t['size']
n = size // 4
words = struct.unpack_from('<%dI' % n, elf.data, off)

# движение по коду: запоминаем последнюю константу в регистре
pools = collections.Counter()
examples = {}

for i in range(n):
    w = words[i]
    # UMULL xD, wA, wB   (0x9BA07C00 маска)
    if (w & 0xFFE0FC00) != 0x9BA07C00:
        continue
    rm = (w >> 16) & 0x1F      # регистр с шагом
    rd = w & 0x1F

    # ищем назад константу шага в rm
    stride = None
    for j in range(i - 1, max(0, i - 12), -1):
        w2 = words[j]
        if (w2 & 0xFFE00000) == 0x52800000 and (w2 & 0x1F) == rm:
            stride = (w2 >> 5) & 0xFFFF
            break
    if not stride or stride < 8 or stride > 20000:
        continue

    # вперёд ищем ldr xR, [xBase, xD] и базу через adrp+add
    for k in range(i + 1, min(i + 14, n)):
        w3 = words[k]
        if (w3 & 0xFFE0FC00) == 0xF8606800 and ((w3 >> 16) & 0x1F) == rd:
            arr_reg = (w3 >> 5) & 0x1F
            add_imm = None
            for m in range(k - 1, max(0, k - 20), -1):
                w4 = words[m]
                if (w4 & 0xFFC00000) == 0x91000000 and (w4 & 0x1F) == arr_reg \
                   and add_imm is None:
                    add_imm = (w4 >> 10) & 0xFFF
                    arr_reg = (w4 >> 5) & 0x1F
                    continue
                if (w4 & 0x9F000000) == 0x90000000 and (w4 & 0x1F) == arr_reg:
                    immlo, immhi = (w4 >> 29) & 3, (w4 >> 5) & 0x7FFFF
                    page = ((base + m * 4) & ~0xFFF) + (sign((immhi << 2) | immlo, 21) << 12)
                    addr = page + (add_imm or 0)
                    pools[(addr, stride)] += 1
                    examples.setdefault((addr, stride), base + i * 4)
                    break
            break

print('найдено пулов (адрес, шаг): %d\n' % len(pools))
print('%-14s %-8s %-8s %-8s %s' % ('адрес', 'шаг', 'раз', 'секция', 'пример'))
for (addr, stride), cnt in pools.most_common(25):
    print('0x%-12X %-8d %-8d %-8s 0x%X' %
          (addr, stride, cnt, elf.sec_of(addr), examples[(addr, stride)]))
