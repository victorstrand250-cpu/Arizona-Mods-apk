"""Перекрёстные ссылки в stripped-библиотеке arm64.

Ищет пары ADRP+ADD (адрес строки/данных) и ADRP+LDR (загрузка через GOT или
поле), собирая таблицу «какой код обращается к какому адресу». Дизассемблер
целиком тут не нужен: интересны ровно два способа получить адрес глобала.
"""
import struct, sys, bisect
from collections import defaultdict

class ELF:
    def __init__(self, path):
        self.data = open(path, 'rb').read()
        d = self.data
        assert d[:4] == b'\x7fELF'
        e_shoff, = struct.unpack_from('<Q', d, 0x28)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from('<HHH', d, 0x3a)
        secs = []
        for i in range(e_shnum):
            o = e_shoff + i * e_shentsize
            name, typ, flags, addr, off, size = struct.unpack_from('<IIQQQQ', d, o)
            secs.append({'name_off': name, 'type': typ, 'addr': addr,
                         'off': off, 'size': size})
        stro = secs[e_shstrndx]['off']
        for s in secs:
            end = d.index(b'\0', stro + s['name_off'])
            s['name'] = d[stro + s['name_off']:end].decode()
        self.secs = secs

    def sec(self, name):
        for s in self.secs:
            if s['name'] == name:
                return s
        return None

    def va_to_off(self, va):
        for s in self.secs:
            if s['type'] != 8 and s['addr'] <= va < s['addr'] + s['size']:
                return s['off'] + (va - s['addr'])
        return None

    def sec_of(self, va):
        for s in self.secs:
            if s['addr'] and s['addr'] <= va < s['addr'] + s['size']:
                return s['name']
        return '?'


def sign(v, bits):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


def scan(elf):
    """-> refs[target_va] = [(code_va, kind), ...]"""
    text = elf.sec('.text')
    base, off, size = text['addr'], text['off'], text['size']
    buf = elf.data[off:off + size]
    refs = defaultdict(list)

    n = size // 4
    words = struct.unpack_from('<%dI' % n, buf, 0)

    # Последний ADRP для каждого регистра, с адресом инструкции.
    for i in range(n):
        w = words[i]
        if (w & 0x9F000000) != 0x90000000:      # ADRP
            continue
        rd = w & 0x1F
        immlo = (w >> 29) & 3
        immhi = (w >> 5) & 0x7FFFF
        imm = sign((immhi << 2) | immlo, 21) << 12
        pc = base + i * 4
        page = (pc & ~0xFFF) + imm

        # Смотрим вперёд немного: компилятор ставит ADD/LDR почти сразу.
        for j in range(i + 1, min(i + 9, n)):
            w2 = words[j]
            # ADD (immediate), 64-bit, shift=0
            if (w2 & 0xFFC00000) == 0x91000000 and ((w2 >> 5) & 0x1F) == rd:
                imm12 = (w2 >> 10) & 0xFFF
                refs[page + imm12].append((pc, 'adrp+add'))
                break
            # LDR (immediate, unsigned offset), 64-bit
            if (w2 & 0xFFC00000) == 0xF9400000 and ((w2 >> 5) & 0x1F) == rd:
                imm12 = ((w2 >> 10) & 0xFFF) * 8
                refs[page + imm12].append((pc, 'adrp+ldr64'))
                break
            # LDR 32-bit
            if (w2 & 0xFFC00000) == 0xB9400000 and ((w2 >> 5) & 0x1F) == rd:
                imm12 = ((w2 >> 10) & 0xFFF) * 4
                refs[page + imm12].append((pc, 'adrp+ldr32'))
                break
            # LDRB
            if (w2 & 0xFFC00000) == 0x39400000 and ((w2 >> 5) & 0x1F) == rd:
                imm12 = (w2 >> 10) & 0xFFF
                refs[page + imm12].append((pc, 'adrp+ldrb'))
                break
            # Регистр перезаписан другим ADRP — дальше не наш.
            if (w2 & 0x9F000000) == 0x90000000 and (w2 & 0x1F) == rd:
                break
    return refs


if __name__ == '__main__':
    elf = ELF(sys.argv[1])
    refs = scan(elf)
    import pickle
    with open(sys.argv[2], 'wb') as f:
        pickle.dump({k: v for k, v in refs.items()}, f)
    print('ссылок собрано: %d, уникальных целей: %d' %
          (sum(len(v) for v in refs.values()), len(refs)))
