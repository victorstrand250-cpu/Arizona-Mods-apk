-- Макросы в чат. Ни одного окна: всё делается командами.
--
--   /bind лечу /me достаёт аптечку | 800 | /do Рана обработана
--   /binds                     список макросов
--   /unbind лечу               убрать
--   /лечу                      выполнить
--
-- Части макроса разделяются вертикальной чертой. Часть из одних цифр — это
-- пауза в миллисекундах, всё остальное уходит в чат как есть. Пауза нужна
-- почти всегда: сервер режет подряд идущие сообщения.
--
-- В тексте макроса раскрываются подстановки:
--   {x} {y} {z}   координаты, одно число после точки
--   {slot}        свой слот
--   {speed}       скорость в км/ч
--   {time}        часы:минуты по телефону

script_name('AutoBind')
script_author('AGLoader')
script_version('1.0')

local ag = require 'arizona'

local binds = {}                     -- имя -> строка макроса
local cfgPath = getPaths().config .. '/autobind.ini'

-- ═══════════════════════════════════════════════════════════════ конфиг

local function saveCfg()
  local f = io.open(cfgPath, 'w')
  if not f then
    log('[AutoBind] не могу писать ' .. cfgPath)
    return
  end
  -- Имена сортируются, чтобы файл не перетасовывался при каждой записи.
  local names = {}
  for name in pairs(binds) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    f:write(name, '=', binds[name], '\n')
  end
  f:close()
end

local function loadCfg()
  local f = io.open(cfgPath, 'r')
  if not f then return end
  for line in f:lines() do
    local k, v = line:match('^([^=]+)=(.*)$')
    if k and v and v ~= '' then binds[k] = v end
  end
  f:close()
end

-- ═════════════════════════════════════════════════════════ подстановки

local function expand(text)
  local me = ag.localPlayer()
  local x, y, z = 0, 0, 0
  local kmh = 0
  if me then
    local px, py, pz = ag.position(me)
    if px then x, y, z = px, py, pz end
    kmh = ag.speedKmh(me) or 0
  end

  local vars = {
    x = ('%.1f'):format(x),
    y = ('%.1f'):format(y),
    z = ('%.1f'):format(z),
    slot = tostring(ag.localIndex() or -1),
    speed = ('%.0f'):format(kmh),
    time = os.date('%H:%M'),
  }
  return (text:gsub('{(%w+)}', function(key)
    return vars[key] or ('{' .. key .. '}')
  end))
end

-- ═══════════════════════════════════════════════════════ выполнение

local running = {}

local function play(name)
  if running[name] then
    log('[AutoBind] «' .. name .. '» ещё выполняется')
    return
  end
  local text = binds[name]
  if not text then return end

  running[name] = true
  lua_thread.create(function()
    for part in text:gmatch('[^|]+') do
      part = part:match('^%s*(.-)%s*$')
      local pause = part:match('^(%d+)$')
      if pause then
        wait(tonumber(pause))
      elseif part ~= '' then
        if not sendChat(expand(part)) then
          log('[AutoBind] чат недоступен — игра ещё не готова')
          break
        end
        -- Даже без явной паузы небольшую выдержку ставим сами: два
        -- сообщения в один кадр сервер почти наверняка склеит.
        wait(350)
      end
    end
    running[name] = false
  end)
end

-- ═══════════════════════════════════════════════════════════ команды

local function register(name)
  registerChatCommand(name, function() play(name) end)
end

local function unregister(name)
  unregisterChatCommand(name)
end

local function cmdBind(arg)
  local name, text = tostring(arg or ''):match('^(%S+)%s+(.+)$')
  if not name then
    log('[AutoBind] /bind <имя> <текст> [| пауза | текст ...]')
    return
  end
  local isNew = binds[name] == nil
  binds[name] = text
  saveCfg()
  if isNew then register(name) end
  log(('[AutoBind] /%s = %s'):format(name, text))
end

local function cmdUnbind(arg)
  local name = tostring(arg or ''):match('^%S+')
  if not name or not binds[name] then
    log('[AutoBind] такого макроса нет')
    return
  end
  binds[name] = nil
  saveCfg()
  unregister(name)
  log('[AutoBind] убран /' .. name)
end

local function cmdList()
  local names = {}
  for name in pairs(binds) do names[#names + 1] = name end
  table.sort(names)
  if #names == 0 then
    log('[AutoBind] макросов нет. Пример: /bind привет Всем привет!')
    return
  end
  log(('[AutoBind] макросов: %d'):format(#names))
  for _, name in ipairs(names) do
    log(('  /%-14s %s'):format(name, binds[name]))
  end
end

-- ═════════════════════════════════════════════════════════════════ main

function main()
  loadCfg()

  registerChatCommand('bind', cmdBind)
  registerChatCommand('unbind', cmdUnbind)
  registerChatCommand('binds', cmdList)

  local n = 0
  for name in pairs(binds) do
    register(name)
    n = n + 1
  end

  log(('[AutoBind] /bind, /unbind, /binds. Загружено макросов: %d'):format(n))
end
