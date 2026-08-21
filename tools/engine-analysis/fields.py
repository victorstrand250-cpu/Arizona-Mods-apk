"""Карта полей структуры игрока.

Находит места, где код берёт указатель из массива игроков
(0x150E950 + индекс*336), и собирает, с какими смещениями этот указатель
потом читают. Частота смещения говорит о его важности, а тип инструкции —
о размере поля.
"""
import struct, sys, collections
sys.path.insert(0, '/tmp/claude-0/-home-user-Arizona-Mods-apk/6ea72e86-5e6b-5f93-ab8e-1ed9cecf90ac/scratchpad')
from xref import ELF, sign

SO = '/tmp/claude-0/-home-user-Arizona-Mods-apk/6ea72e86-5e6b-5f93-ab8e-1ed9cecf90ac/scratchpad/work/new_x/lib/arm64-v8a/libag-client.so'
ARRAY_PAGE, ARRAY_OFF = 0x150E000, 0x950

elf = ELF(SO)
t = elf.sec('.text')
base, off, size = t['addr'], t['off'], t['size']
n = size // 4
words = struct.unpack_from('<%dI' % n, elf.data, off)

# Формы загрузки/записи: (маска, значение, множитель смещения, подпись)
LOADS = [
    (0xFFC00000, 0xF9400000, 8, 'ldr  x'),
    (0xFFC00000, 0xB9400000, 4, 'ldr  w'),
    (0xFFC00000, 0x79400000, 2, 'ldrh w'),
    (0xFFC00000, 0x39400000, 1, 'ldrb w'),
    (0xFFC00000, 0xBD400000, 4, 'ldr  s'),   # float
    (0xFFC00000, 0xFD400000, 8, 'ldr  d'),
    (0xFFC00000, 0xF9000000, 8, 'str  x'),
    (0xFFC00000, 0xB9000000, 4, 'str  w'),
    (0xFFC00000, 0x79000000, 2, 'strh w'),
    (0xFFC00000, 0x39000000, 1, 'strb w'),
    (0xFFC00000, 0xBD000000, 4, 'str  s'),
]

def decode_mem(w):
    for mask, val, mult, name in LOADS:
        if (w & mask) == val:
            rt = w & 0x1F
            rn = (w >> 5) & 0x1F
            imm = ((w >> 10) & 0xFFF) * mult
            return name, rt, rn, imm
    return None

# 1. Находим ldr xD, [xBase, xIdx] сразу после adrp+add на массив.
anchors = []
for i in range(n):
    w = words[i]
    if (w & 0x9F000000) != 0x90000000:
        continue
    immlo = (w >> 29) & 3
    immhi = (w >> 5) & 0x7FFFF
    page = ((base + i * 4) & ~0xFFF) + (sign((immhi << 2) | immlo, 21) << 12)
    if page != ARRAY_PAGE:
        continue
    rd = w & 0x1F
    # add xN, xN, #0x950
    for j in range(i + 1, min(i + 6, n)):
        w2 = words[j]
        if (w2 & 0xFFC00000) == 0x91000000 and ((w2 >> 5) & 0x1F) == rd \
           and ((w2 >> 10) & 0xFFF) == ARRAY_OFF:
            arr_reg = w2 & 0x1F
            # ldr xD, [arr_reg, xIdx]  — регистровое индексирование
            for k in range(j + 1, min(j + 10, n)):
                w3 = words[k]
                if (w3 & 0xFFE0FC00) == 0xF8606800 and ((w3 >> 5) & 0x1F) == arr_reg:
                    anchors.append((k, w3 & 0x1F))
                    break
            break

print('мест, где берут указатель игрока из массива: %d\n' % len(anchors))

# 2. От каждого места смотрим вперёд: чем трогают этот регистр.
fields = collections.defaultdict(collections.Counter)
examples = {}
for idx, reg in anchors:
    cur = reg
    for j in range(idx + 1, min(idx + 60, n)):
        w = words[j]
        dec = decode_mem(w)
        if dec:
            name, rt, rn, imm = dec
            if rn == cur:
                fields[imm][name] += 1
                examples.setdefault((imm, name), base + j * 4)
                # Загрузка в тот же регистр — дальше там уже не игрок,
                # а его поле, и считать его смещения от игрока нельзя.
                if rt == cur and name.startswith('ldr'):
                    break
                continue
            # Регистр перезаписали загрузкой откуда-то ещё.
            if rt == cur and name.startswith('ldr'):
                break
        # регистр перезаписали — дальше это уже не игрок
        if (w & 0xFFE0FC00) == 0xF8606800 and (w & 0x1F) == cur:
            break
        if (w & 0x9F000000) == 0x90000000 and (w & 0x1F) == cur:
            break

print('%-8s %-8s %-6s %s' % ('смещ.', 'как', 'раз', 'пример кода'))
rows = sorted(fields.items(), key=lambda kv: -sum(kv[1].values()))
for imm, kinds in rows[:45]:
    for name, cnt in kinds.most_common(2):
        print('%-8s %-8s %-6d 0x%X' % ('+%d' % imm, name, cnt, examples[(imm, name)]))
