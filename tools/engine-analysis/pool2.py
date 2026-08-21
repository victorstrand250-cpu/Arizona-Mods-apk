"""Карта полей объекта из пула 0x3110540."""
import struct, sys, collections
sys.path.insert(0, '/tmp/claude-0/-home-user-Arizona-Mods-apk/6ea72e86-5e6b-5f93-ab8e-1ed9cecf90ac/scratchpad')
from xref import ELF, sign

SO = '/tmp/claude-0/-home-user-Arizona-Mods-apk/6ea72e86-5e6b-5f93-ab8e-1ed9cecf90ac/scratchpad/work/new_x/lib/arm64-v8a/libag-client.so'
elf = ELF(SO)
t = elf.sec('.text'); base, off, size = t['addr'], t['off'], t['size']
n = size // 4
words = struct.unpack_from('<%dI' % n, elf.data, off)

LOADS = [
    (0xFFC00000, 0xF9400000, 8, 'ldr  x'), (0xFFC00000, 0xB9400000, 4, 'ldr  w'),
    (0xFFC00000, 0x79400000, 2, 'ldrh w'), (0xFFC00000, 0x39400000, 1, 'ldrb w'),
    (0xFFC00000, 0xBD400000, 4, 'ldr  s'), (0xFFC00000, 0xFD400000, 8, 'ldr  d'),
    (0xFFC00000, 0xF9000000, 8, 'str  x'), (0xFFC00000, 0xB9000000, 4, 'str  w'),
    (0xFFC00000, 0x39000000, 1, 'strb w'), (0xFFC00000, 0xBD000000, 4, 'str  s'),
]
def dec(w):
    for mask, val, mult, name in LOADS:
        if (w & mask) == val:
            return name, w & 0x1F, (w >> 5) & 0x1F, ((w >> 10) & 0xFFF) * mult
    return None

anchors = []
for i in range(n):
    w = words[i]
    if (w & 0xFFE0FC00) != 0xF8607800:
        continue
    arr_reg = (w >> 5) & 0x1F
    add_imm = None
    for m in range(i-1, max(0, i-20), -1):
        w4 = words[m]
        if (w4 & 0xFFC00000)==0x91000000 and (w4 & 0x1F)==arr_reg and add_imm is None:
            add_imm=(w4>>10)&0xFFF; arr_reg=(w4>>5)&0x1F; continue
        if (w4 & 0x9F000000)==0x90000000 and (w4 & 0x1F)==arr_reg:
            immlo,immhi=(w4>>29)&3,(w4>>5)&0x7FFFF
            page=((base+m*4)&~0xFFF)+(sign((immhi<<2)|immlo,21)<<12)
            if page + (add_imm or 0) == 0x3110540:
                anchors.append((i, w & 0x1F))
            break

print('мест, где берут объект из пула: %d\n' % len(anchors))

fields = collections.defaultdict(collections.Counter); ex = {}
for idx, reg in anchors:
    for j in range(idx+1, min(idx+50, n)):
        w = words[j]
        d = dec(w)
        if d:
            name, rt, rn, imm = d
            if rn == reg:
                fields[imm][name] += 1
                ex.setdefault((imm,name), base+j*4)
                if rt == reg and name.startswith('ldr'): break
                continue
            if rt == reg and name.startswith('ldr'): break
        if (w & 0xFFE0FC00)==0xF8607800 and (w & 0x1F)==reg: break

print('%-8s %-8s %-6s %s' % ('смещ.','как','раз','пример'))
for imm, kinds in sorted(fields.items(), key=lambda kv: -sum(kv[1].values()))[:26]:
    for name, cnt in kinds.most_common(2):
        print('%-8s %-8s %-6d 0x%X' % ('+%d'%imm, name, cnt, ex[(imm,name)]))
