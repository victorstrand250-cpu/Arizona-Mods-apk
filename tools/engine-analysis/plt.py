"""Сопоставляет PLT-заглушки с именами импортов и ищет, кто их зовёт.

В stripped-библиотеке имена своих функций стёрты, но имена импортов из
libGLESv3 и libc остаются в .dynsym — через них можно зацепиться за код.
"""
import struct, sys
sys.path.insert(0, '/tmp/claude-0/-home-user-Arizona-Mods-apk/6ea72e86-5e6b-5f93-ab8e-1ed9cecf90ac/scratchpad')
from xref import ELF, sign

SO = '/tmp/claude-0/-home-user-Arizona-Mods-apk/6ea72e86-5e6b-5f93-ab8e-1ed9cecf90ac/scratchpad/work/new_x/lib/arm64-v8a/libag-client.so'
elf = ELF(SO)
d = elf.data

# .dynsym -> имена
dynsym = elf.sec('.dynsym'); dynstr = elf.sec('.dynstr')
names = []
n = dynsym['size'] // 24
for i in range(n):
    o = dynsym['off'] + i * 24
    st_name, = struct.unpack_from('<I', d, o)
    end = d.index(b'\0', dynstr['off'] + st_name)
    names.append(d[dynstr['off'] + st_name:end].decode())

# .rela.plt: R_AARCH64_JUMP_SLOT -> got-слот и индекс символа
rela = elf.sec('.rela.plt')
got_to_name = {}
if rela:
    for i in range(rela['size'] // 24):
        o = rela['off'] + i * 24
        r_offset, r_info, r_addend = struct.unpack_from('<QQq', d, o)
        sym = r_info >> 32
        if sym < len(names):
            got_to_name[r_offset] = names[sym]

# PLT: каждая заглушка 16 байт, читает свой GOT-слот через adrp+ldr
plt = elf.sec('.plt')
stub_to_name = {}
if plt:
    base, off = plt['addr'], plt['off']
    count = plt['size'] // 16
    for i in range(count):
        va = base + i * 16
        w = struct.unpack_from('<4I', d, off + i * 16)
        page = None
        for j, ins in enumerate(w):
            if (ins & 0x9F000000) == 0x90000000:          # ADRP
                immlo = (ins >> 29) & 3
                immhi = (ins >> 5) & 0x7FFFF
                page = ((va + j * 4) & ~0xFFF) + (sign((immhi << 2) | immlo, 21) << 12)
            elif page is not None and (ins & 0xFFC00000) == 0xF9400000:  # LDR
                slot = page + (((ins >> 10) & 0xFFF) * 8)
                if slot in got_to_name:
                    stub_to_name[va] = got_to_name[slot]
                break

if __name__ == '__main__':
    want = sys.argv[1:] or ['glBufferSubData', 'glUniformMatrix4fv', 'glUniform4fv']
    rev = {}
    for va, nm in stub_to_name.items():
        rev.setdefault(nm, []).append(va)
    print('заглушек PLT разобрано: %d' % len(stub_to_name))
    for w in want:
        for nm, vas in rev.items():
            if w in nm:
                print('  %-28s -> %s' % (nm, ', '.join('0x%X' % v for v in vas)))
