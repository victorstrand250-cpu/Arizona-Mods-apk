-- Перекодировка для AGLoader — замена MoonLoader-овского encoding.
--
-- Оригинал держался на C-модуле iconv, которого у нас нет, поэтому здесь
-- всё на чистом Lua. Поддерживаются CP1251 и UTF-8 — этого хватает: почти
-- все русские скрипты написаны в CP1251 и гоняют текст через u8.
--
-- Использование ровно как в MoonLoader:
--
--   local encoding = require 'encoding'
--   encoding.default = 'CP1251'
--   local u8 = encoding.UTF8
--
--   local utf = u8'\xd2\xe5\xea\xf1\xf2'   -- CP1251 -> UTF-8
--   local cp  = u8:decode(utf)              -- UTF-8 -> CP1251

local encoding = {}
encoding.default = 'CP1251'

-- Таблица CP1251: байт 0x80..0xFF -> кодовая точка Unicode.
-- Нижняя половина совпадает с ASCII и в таблице не нужна.
local CP1251_TO_UNICODE = {
  1026, 1027, 8218, 1107, 8222, 8230, 8224, 8225,
  8364, 8240, 1033, 8249, 1034, 1036, 1035, 1039,
  1106, 8216, 8217, 8220, 8221, 8226, 8211, 8212,
  nil, 8482, 1113, 8250, 1114, 1116, 1115, 1119,
  160, 1038, 1118, 1032, 164, 1168, 166, 167,
  1025, 169, 1028, 171, 172, 173, 174, 1031,
  176, 177, 1030, 1110, 1169, 181, 182, 183,
  1105, 8470, 1108, 187, 1112, 1029, 1109, 1111,
  1040, 1041, 1042, 1043, 1044, 1045, 1046, 1047,
  1048, 1049, 1050, 1051, 1052, 1053, 1054, 1055,
  1056, 1057, 1058, 1059, 1060, 1061, 1062, 1063,
  1064, 1065, 1066, 1067, 1068, 1069, 1070, 1071,
  1072, 1073, 1074, 1075, 1076, 1077, 1078, 1079,
  1080, 1081, 1082, 1083, 1084, 1085, 1086, 1087,
  1088, 1089, 1090, 1091, 1092, 1093, 1094, 1095,
  1096, 1097, 1098, 1099, 1100, 1101, 1102, 1103,
}

-- Обратная таблица строится один раз при загрузке.
local UNICODE_TO_CP1251 = {}
for byte = 0x80, 0xFF do
  local cp = CP1251_TO_UNICODE[byte - 0x7F]
  if cp then
    UNICODE_TO_CP1251[cp] = byte
  end
end

local char, byte_of = string.char, string.byte

-- Кодовая точка -> последовательность UTF-8.
local function utf8_char(cp)
  if cp < 0x80 then
    return char(cp)
  elseif cp < 0x800 then
    return char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
  elseif cp < 0x10000 then
    return char(0xE0 + math.floor(cp / 0x1000),
                0x80 + (math.floor(cp / 0x40) % 0x40),
                0x80 + (cp % 0x40))
  end
  return char(0xF0 + math.floor(cp / 0x40000),
              0x80 + (math.floor(cp / 0x1000) % 0x40),
              0x80 + (math.floor(cp / 0x40) % 0x40),
              0x80 + (cp % 0x40))
end

-- Разбор одного символа UTF-8. Возвращает кодовую точку и позицию следующего.
-- Битая последовательность не роняет разбор: отдаём байт как есть.
local function utf8_decode(s, i)
  local c = byte_of(s, i)
  if not c then return nil, i end
  if c < 0x80 then
    return c, i + 1
  elseif c < 0xC0 then
    return c, i + 1              -- одинокий хвостовой байт
  elseif c < 0xE0 then
    local c2 = byte_of(s, i + 1)
    if not c2 then return c, i + 1 end
    return (c - 0xC0) * 0x40 + (c2 - 0x80), i + 2
  elseif c < 0xF0 then
    local c2, c3 = byte_of(s, i + 1), byte_of(s, i + 2)
    if not c2 or not c3 then return c, i + 1 end
    return (c - 0xE0) * 0x1000 + (c2 - 0x80) * 0x40 + (c3 - 0x80), i + 3
  end
  local c2, c3, c4 = byte_of(s, i + 1), byte_of(s, i + 2), byte_of(s, i + 3)
  if not c2 or not c3 or not c4 then return c, i + 1 end
  return (c - 0xF0) * 0x40000 + (c2 - 0x80) * 0x1000
         + (c3 - 0x80) * 0x40 + (c4 - 0x80), i + 4
end

local function cp1251_to_utf8(s)
  local out = {}
  for i = 1, #s do
    local b = byte_of(s, i)
    if b < 0x80 then
      out[#out + 1] = char(b)
    else
      local cp = CP1251_TO_UNICODE[b - 0x7F]
      out[#out + 1] = cp and utf8_char(cp) or '?'
    end
  end
  return table.concat(out)
end

local function utf8_to_cp1251(s)
  local out = {}
  local i = 1
  while i <= #s do
    local cp, nxt = utf8_decode(s, i)
    if not cp then break end
    i = nxt
    if cp < 0x80 then
      out[#out + 1] = char(cp)
    else
      local b = UNICODE_TO_CP1251[cp]
      out[#out + 1] = b and char(b) or '?'
    end
  end
  return table.concat(out)
end

local function normalize(name)
  name = tostring(name or encoding.default):lower():gsub('[%s_-]', '')
  if name == 'cp1251' or name == 'windows1251' or name == 'win1251'
     or name == 'ansi' then
    return 'cp1251'
  end
  if name == 'utf8' or name == 'utf' then
    return 'utf8'
  end
  return name
end

-- Объект-конвертер. Вызов как функции — то же, что encode.
local UTF8 = {}

function UTF8.encode(_, text, from)
  if type(_) == 'string' then       -- вызвали через точку, а не двоеточие
    text, from = _, text
  end
  local src = normalize(from)
  if src == 'utf8' then return text end
  if src ~= 'cp1251' then
    return text                     -- незнакомая кодировка — не трогаем
  end
  return cp1251_to_utf8(text)
end

function UTF8.decode(_, text, to)
  if type(_) == 'string' then
    text, to = _, text
  end
  local dst = normalize(to)
  if dst == 'utf8' then return text end
  if dst ~= 'cp1251' then
    return text
  end
  return utf8_to_cp1251(text)
end

setmetatable(UTF8, {
  __call = function(self, text, from) return UTF8.encode(self, text, from) end,
})

encoding.UTF8 = UTF8

-- Прямые функции — иногда удобнее объекта.
encoding.cp1251_to_utf8 = cp1251_to_utf8
encoding.utf8_to_cp1251 = utf8_to_cp1251

return encoding
