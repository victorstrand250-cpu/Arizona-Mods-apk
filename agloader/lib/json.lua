-- JSON для AGLoader — замена C-модуля cjson.
--
-- Скрипты MonetLoader тянут cjson, которого у нас нет, поэтому здесь чистый
-- Lua. Совместимо по вызовам: encode/decode, плюс алиасы cjson-овских имён.
--
--   local json = require 'json'
--   local t = json.decode('{"a":[1,2,3]}')
--   local s = json.encode(t)
--
-- Отдельная забота — пустая таблица. В Lua не отличить пустой список от
-- пустого словаря, поэтому пустая таблица кодируется как {}, а получить []
-- можно через json.array{} или json.empty_array.

local json = {}

-- ═══════════════════════════════════════════════════════════════ разбор

local escapes = {
  ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
  b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
}

local function skip_space(s, i)
  local _, j = s:find('^[ \t\r\n]*', i)
  return j + 1
end

local function parse_error(s, i, msg)
  -- Номер строки считаем на месте: ошибки в конфигах ищутся по нему.
  local line = 1
  for _ in s:sub(1, i):gmatch('\n') do line = line + 1 end
  error(('json: %s (строка %d, символ %d)'):format(msg, line, i), 0)
end

-- Кодовая точка -> UTF-8. Нужна для \uXXXX.
local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000),
                       0x80 + math.floor(cp / 0x40) % 0x40,
                       0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000),
                     0x80 + math.floor(cp / 0x1000) % 0x40,
                     0x80 + math.floor(cp / 0x40) % 0x40,
                     0x80 + cp % 0x40)
end

local parse_value

local function parse_string(s, i)
  i = i + 1                       -- пропустить открывающую кавычку
  local out = {}
  while true do
    local c = s:sub(i, i)
    if c == '' then
      parse_error(s, i, 'строка не закрыта')
    elseif c == '"' then
      return table.concat(out), i + 1
    elseif c == '\\' then
      local e = s:sub(i + 1, i + 1)
      if escapes[e] then
        out[#out + 1] = escapes[e]
        i = i + 2
      elseif e == 'u' then
        local hex = s:sub(i + 2, i + 5)
        local cp = tonumber(hex, 16)
        if not cp then parse_error(s, i, 'битый \\u') end
        i = i + 6
        -- Суррогатная пара: старшая половина плюс младшая дают один символ.
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(i, i + 1) == '\\u' then
          local lo = tonumber(s:sub(i + 2, i + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            i = i + 6
          end
        end
        out[#out + 1] = utf8_char(cp)
      else
        parse_error(s, i, 'неизвестный escape \\' .. e)
      end
    else
      -- Забираем куском до ближайшей кавычки или обратного слэша.
      local nxt = s:find('["\\]', i)
      if not nxt then parse_error(s, i, 'строка не закрыта') end
      out[#out + 1] = s:sub(i, nxt - 1)
      i = nxt
    end
  end
end

local function parse_number(s, i)
  local j = s:find('[^0-9eE%+%-%.]', i) or (#s + 1)
  local text = s:sub(i, j - 1)
  local num = tonumber(text)
  if not num then parse_error(s, i, 'не число: ' .. text) end
  return num, j
end

local function parse_array(s, i)
  local out = {}
  i = skip_space(s, i + 1)
  if s:sub(i, i) == ']' then return out, i + 1 end
  while true do
    local v
    v, i = parse_value(s, i)
    out[#out + 1] = v
    i = skip_space(s, i)
    local c = s:sub(i, i)
    if c == ',' then
      i = skip_space(s, i + 1)
    elseif c == ']' then
      return out, i + 1
    else
      parse_error(s, i, "ожидалась ',' или ']'")
    end
  end
end

local function parse_object(s, i)
  local out = {}
  i = skip_space(s, i + 1)
  if s:sub(i, i) == '}' then return out, i + 1 end
  while true do
    if s:sub(i, i) ~= '"' then parse_error(s, i, 'ключ должен быть строкой') end
    local k
    k, i = parse_string(s, i)
    i = skip_space(s, i)
    if s:sub(i, i) ~= ':' then parse_error(s, i, "ожидалось ':'") end
    i = skip_space(s, i + 1)

    local v
    v, i = parse_value(s, i)
    out[k] = v
    i = skip_space(s, i)

    local c = s:sub(i, i)
    if c == ',' then
      i = skip_space(s, i + 1)
    elseif c == '}' then
      return out, i + 1
    else
      parse_error(s, i, "ожидалась ',' или '}'")
    end
  end
end

parse_value = function(s, i)
  i = skip_space(s, i)
  local c = s:sub(i, i)
  if c == '{' then return parse_object(s, i) end
  if c == '[' then return parse_array(s, i) end
  if c == '"' then return parse_string(s, i) end
  if c == 't' and s:sub(i, i + 3) == 'true'  then return true,  i + 4 end
  if c == 'f' and s:sub(i, i + 4) == 'false' then return false, i + 5 end
  if c == 'n' and s:sub(i, i + 3) == 'null'  then return json.null, i + 4 end
  if c:match('[%-0-9]') then return parse_number(s, i) end
  if c == '' then parse_error(s, i, 'пустой ввод') end
  parse_error(s, i, 'неожиданный символ ' .. c)
end

-- null отдельным значением: nil в таблице Lua неотличим от отсутствия ключа.
json.null = setmetatable({}, { __tostring = function() return 'null' end })

function json.decode(text)
  if type(text) ~= 'string' then
    error('json.decode: ожидалась строка', 2)
  end
  local ok, value, rest = pcall(parse_value, text, 1)
  if not ok then
    return nil, value
  end
  rest = skip_space(text, rest)
  if rest <= #text then
    return nil, 'json: лишние данные после значения'
  end
  return value
end

-- ══════════════════════════════════════════════════════════════ сборка

local char_to_escape = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function escape_string(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return char_to_escape[c] or ('\\u%04x'):format(c:byte())
  end) .. '"'
end

-- Список или словарь: список — это 1..n без дырок и без чужих ключей.
local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= 'number' then return false end
    n = n + 1
  end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true, n
end

-- Метка «это список»: пустая таблица иначе неотличима от пустого словаря.
local array_mt = { __tostring = function() return '[]' end }

local encode_value

local function encode_table(t, indent, level, seen)
  if seen[t] then
    error('json.encode: таблица ссылается сама на себя', 0)
  end
  seen[t] = true

  local nl, pad, pad2 = '', '', ''
  if indent then
    nl = '\n'
    pad = string.rep(indent, level + 1)
    pad2 = string.rep(indent, level)
  end

  local out
  local array, n = is_array(t)
  if getmetatable(t) == array_mt then
    array, n = true, n or 0
  end
  if array and n and n > 0 then
    out = { '[' }
    for i = 1, n do
      out[#out + 1] = (i > 1 and ',' or '') .. nl .. pad
      out[#out + 1] = encode_value(t[i], indent, level + 1, seen)
    end
    out[#out + 1] = nl .. pad2 .. ']'
  elseif array and getmetatable(t) ~= array_mt then
    out = { '{}' }
  elseif array then
    out = { '[]' }
  else
    -- Ключи сортируем: так один и тот же конфиг всегда выглядит одинаково
    -- и его удобно сравнивать.
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    out = { '{' }
    for i, k in ipairs(keys) do
      out[#out + 1] = (i > 1 and ',' or '') .. nl .. pad
      out[#out + 1] = escape_string(tostring(k)) .. (indent and ': ' or ':')
      out[#out + 1] = encode_value(t[k], indent, level + 1, seen)
    end
    out[#out + 1] = nl .. pad2 .. '}'
  end

  seen[t] = nil
  return table.concat(out)
end

encode_value = function(v, indent, level, seen)
  local tv = type(v)
  if v == json.null or v == nil then return 'null' end
  if tv == 'boolean' then return tostring(v) end
  if tv == 'string' then return escape_string(v) end
  if tv == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then
      return 'null'          -- NaN и бесконечности в JSON не бывает
    end
    if v == math.floor(v) and math.abs(v) < 1e15 then
      return ('%d'):format(v)
    end
    return ('%.14g'):format(v)
  end
  if tv == 'table' then return encode_table(v, indent, level, seen) end
  error('json.encode: нельзя закодировать ' .. tv, 0)
end

-- json.encode(значение, [отступ])
-- Отступ строкой ('  ') или true — тогда два пробела.
function json.encode(value, indent)
  if indent == true then indent = '  ' end
  local ok, res = pcall(encode_value, value, indent, 0, {})
  if not ok then
    return nil, res
  end
  return res
end

-- Пустой список: без метки пустая таблица станет {}.
json.empty_array = setmetatable({}, array_mt)

function json.array(t)
  return setmetatable(t or {}, array_mt)
end

-- Имена в духе cjson, чтобы старые скрипты не переписывать.
json.safe = json

return json
