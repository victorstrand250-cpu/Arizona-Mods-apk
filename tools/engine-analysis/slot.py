"""Карта 336-байтового слота игрока.

Массив по 0x150E950 хранит слоты фиксированного размера. Указатель на объект
лежит в начале слота, но остальные 328 байт тоже чем-то заняты — там же
обычно ник, счёт и прочее по игроку. Ищем места, где код считает адрес
слота (base + индекс*336) и читает от него по смещениям.
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

LOADS = [
    (0xFFC00000, 0xF9400000, 8, 'ldr  x'), (0xFFC00000, 0xB9400000, 4, 'ldr  w'),
    (0xFFC00000, 0x79400000, 2, 'ldrh w'), (0xFFC00000, 0x39400000, 1, 'ldrb w'),
    (0xFFC00000, 0xBD400000, 4, 'ldr  s'), (0xFFC00000, 0xF9000000, 8, 'str  x'),
    (0xFFC00000, 0xB9000000, 4, 'str  w'), (0xFFC00000, 0x79000000, 2, 'strh w'),
    (0xFFC00000, 0x39000000, 1, 'strb w'), (0xFFC00000, 0xBD000000, 4, 'str  s'),
]

def decode_mem(w):
    for mask, val, mult, name in LOADS:
        if (w & mask) == val:
            return name, w & 0x1F, (w >> 5) & 0x1F, ((w >> 10) & 0xFFF) * mult
    return None

# Ищем: add xSlot, xArrBase, xIndexScaled  — адрес самого слота.
# В коде это обычно add xN, xArr, xOff  сразу после adrp+add на массив.
slots = []
for i in range(n):
    w = words[i]
    if (w & 0x9F000000) != 0x90000000:
        continue
    immlo, immhi = (w >> 29) & 3, (w >> 5) & 0x7FFFF
    page = ((base + i * 4) & ~0xFFF) + (sign((immhi << 2) | immlo, 21) << 12)
    if page != 0x150E000:
        continue
    rd = w & 0x1F
    for j in range(i + 1, min(i + 6, n)):
        w2 = words[j]
        if (w2 & 0xFFC00000) == 0x91000000 and ((w2 >> 5) & 0x1F) == rd \
           and ((w2 >> 10) & 0xFFF) == 0x950:
            arr = w2 & 0x1F
            # add xSlot, arr, xIdx  (регистровое сложение, shift 0)
            for k in range(j + 1, min(j + 12, n)):
                w3 = words[k]
                if (w3 & 0xFFE0FC00) == 0x8B000000 and ((w3 >> 5) & 0x1F) == arr:
                    slots.append((k, w3 & 0x1F))
                    break
            break

print('мест, где считают адрес слота: %d\n' % len(slots))

fields = collections.defaultdict(collections.Counter)
examples = {}
for idx, reg in slots:
    for j in range(idx + 1, min(idx + 50, n)):
        w = words[j]
        dec = decode_mem(w)
        if dec:
            name, rt, rn, imm = dec
            if rn == reg:
                fields[imm][name] += 1
                examples.setdefault((imm, name), base + j * 4)
                if rt == reg and name.startswith('ldr'):
                    break
                continue
            if rt == reg and name.startswith('ldr'):
                break
        if (w & 0xFFE0FC00) == 0x8B000000 and (w & 0x1F) == reg:
            break

print('%-8s %-8s %-6s %s' % ('смещ.', 'как', 'раз', 'пример'))
for imm, kinds in sorted(fields.items(), key=lambda kv: -sum(kv[1].values()))[:30]:
    for name, cnt in kinds.most_common(2):
        print('%-8s %-8s %-6d 0x%X' % ('+%d' % imm, name, cnt, examples[(imm, name)]))
