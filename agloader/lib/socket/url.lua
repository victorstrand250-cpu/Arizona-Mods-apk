-- Разбор и сборка адресов, как в socket.url из LuaSocket.
--
--   local url = require 'socket.url'
--   local t = url.parse('https://site.ru:8080/path?a=1#top')
--   t.scheme t.host t.port t.path t.query t.fragment

local url = {}

-- Экранирование для percent-encoding.
function url.escape(s)
  return (tostring(s):gsub('[^A-Za-z0-9%-_%.~]', function(c)
    return ('%%%02X'):format(c:byte())
  end))
end

function url.unescape(s)
  return (tostring(s):gsub('%%(%x%x)', function(h)
    return string.char(tonumber(h, 16))
  end))
end

-- Разбор по частям. Ничего не выдумываем: чего нет, того нет.
function url.parse(text, default)
  local parsed = {}
  for k, v in pairs(default or {}) do parsed[k] = v end

  text = tostring(text or '')

  text = text:gsub('#(.*)$', function(f) parsed.fragment = f; return '' end)
  text = text:gsub('^([%w][%w%+%-%.]*)%:', function(s)
    parsed.scheme = s:lower(); return ''
  end)
  text = text:gsub('^//([^/]*)', function(a) parsed.authority = a; return '' end)
  text = text:gsub('%?(.*)', function(q) parsed.query = q; return '' end)

  if text ~= '' then parsed.path = text end

  local auth = parsed.authority
  if auth then
    auth = auth:gsub('^([^@]*)@', function(u) parsed.userinfo = u; return '' end)
    auth = auth:gsub(':(%d+)$', function(p) parsed.port = tonumber(p); return '' end)
    if auth ~= '' then parsed.host = auth end
    if parsed.userinfo then
      parsed.user = parsed.userinfo:match('^([^:]*)')
      parsed.password = parsed.userinfo:match(':(.*)$')
    end
  end

  if not parsed.port and parsed.scheme then
    parsed.port = (parsed.scheme == 'https') and 443
                  or (parsed.scheme == 'http') and 80 or nil
  end
  return parsed
end

function url.build(t)
  local out = ''
  if t.scheme then out = t.scheme .. ':' end
  local auth = t.host
  if auth then
    if t.user then
      auth = t.user .. (t.password and (':' .. t.password) or '') .. '@' .. auth
    end
    local scheme_port = (t.scheme == 'https' and 443)
                        or (t.scheme == 'http' and 80) or nil
    if t.port and t.port ~= scheme_port then auth = auth .. ':' .. t.port end
    out = out .. '//' .. auth
  end
  out = out .. (t.path or '')
  if t.query then out = out .. '?' .. t.query end
  if t.fragment then out = out .. '#' .. t.fragment end
  return out
end

-- Собирает строку запроса из таблицы: { a = 1, b = 'да' } -> 'a=1&b=%D0%B4%D0%B0'
-- Ключи сортируются, чтобы один и тот же набор давал одинаковую строку.
function url.buildquery(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)

  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = url.escape(k) .. '=' .. url.escape(t[k])
  end
  return table.concat(parts, '&')
end

function url.parsequery(s)
  local out = {}
  for pair in tostring(s or ''):gmatch('[^&]+') do
    local k, v = pair:match('^([^=]*)=?(.*)$')
    if k and k ~= '' then out[url.unescape(k)] = url.unescape(v) end
  end
  return out
end

return url
