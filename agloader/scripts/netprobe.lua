-- Сеть без окна: проверка того, что нативные модули действительно на месте.
--
--   /tcping example.com 80    достучаться сырым сокетом TCP
--   /dns example.com          узнать адрес
--   /geturl https://...       забрать страницу
--   /netinfo                  какие модули поднялись
--
-- Всё уходит в лог загрузчика. Сырые сокеты здесь настоящие — из LuaSocket,
-- собранного в загрузчик; HTTP идёт системным стеком Android, поэтому и
-- HTTPS работает без OpenSSL.

script_name('NetProbe')
script_author('AGLoader')
script_version('1.0')

-- Модули подключаются лениво и через pcall: если нативная часть почему-то
-- не поднялась, скрипт должен сказать об этом словами, а не упасть.
local function take(name)
  local ok, mod = pcall(require, name)
  if ok then return mod end
  return nil, tostring(mod)
end

-- ═══════════════════════════════════════════════════════════ tcping

local function tcping(arg)
  local host, port = tostring(arg or ''):match('^(%S+)%s*(%d*)$')
  if not host or host == '' then
    log('[NetProbe] /tcping <хост> [порт]')
    return
  end
  port = tonumber(port) or 80

  local socket, err = take('socket')
  if not socket then
    log('[NetProbe] socket недоступен: ' .. err)
    return
  end

  lua_thread.create(function()
    local c = socket.tcp()
    if not c then log('[NetProbe] не создался сокет'); return end

    -- Обязательно: без таймаута блокирующий connect подвесил бы кадр
    -- ровно на столько, сколько молчит та сторона.
    c:settimeout(3)

    local t0 = socket.gettime()
    local ok, why = c:connect(host, port)
    local ms = (socket.gettime() - t0) * 1000
    c:close()

    if ok then
      log(('[NetProbe] %s:%d — отвечает, %.0f мс'):format(host, port, ms))
    else
      log(('[NetProbe] %s:%d — не отвечает: %s'):format(host, port,
          tostring(why)))
    end
  end)
end

-- ══════════════════════════════════════════════════════════════ dns

local function dns(arg)
  local host = tostring(arg or ''):match('^%S+')
  if not host then log('[NetProbe] /dns <хост>'); return end

  local socket, err = take('socket')
  if not socket then
    log('[NetProbe] socket недоступен: ' .. err)
    return
  end

  lua_thread.create(function()
    local ip, info = socket.dns.toip(host)
    if not ip then
      log('[NetProbe] ' .. host .. ' не разрешается: ' .. tostring(info))
      return
    end
    log('[NetProbe] ' .. host .. ' -> ' .. ip)
    for _, alias in ipairs((info or {}).ip or {}) do
      if alias ~= ip then log('    ещё ' .. alias) end
    end
  end)
end

-- ═══════════════════════════════════════════════════════════ geturl

local function geturl(arg)
  local url = tostring(arg or ''):match('^%S+')
  if not url then log('[NetProbe] /geturl <адрес>'); return end

  local requests, err = take('requests')
  if not requests then
    log('[NetProbe] requests недоступен: ' .. err)
    return
  end

  lua_thread.create(function()
    local r = requests.get(url)
    if not r or r.error then
      log('[NetProbe] ошибка: ' .. tostring(r and r.error or 'нет ответа'))
      return
    end
    log(('[NetProbe] код %d, тело %d байт'):format(r.status_code, #(r.text or '')))
    -- Первая строка ответа: чаще всего этого хватает, чтобы понять, то ли
    -- пришло, а весь HTML в лог сваливать незачем.
    local first = (r.text or ''):match('^[^\n]*')
    if first and first ~= '' then
      log('    ' .. first:sub(1, 160))
    end
  end)
end

-- ══════════════════════════════════════════════════════════ netinfo

local function netinfo()
  local rows = {
    { 'socket.core', 'сырые сокеты TCP и UDP' },
    { 'mime.core',   'кодирование base64 и quoted-printable' },
    { 'cjson',       'быстрый JSON на C' },
    { 'lfs',         'работа с файловой системой' },
    { 'socket',      'обёртка LuaSocket' },
    { 'socket.http', 'HTTP и HTTPS через стек Android' },
    { 'ssl.https',   'привычное имя для HTTPS' },
    { 'ltn12',       'фильтры и насосы' },
    { 'requests',    'простой клиент' },
  }
  log('[NetProbe] модули:')
  for _, row in ipairs(rows) do
    local mod, err = take(row[1])
    if mod then
      local ver = type(mod) == 'table'
                  and (mod._VERSION or mod.version or '') or ''
      log(('  есть  %-12s %s %s'):format(row[1], row[2], tostring(ver)))
    else
      log(('  НЕТ   %-12s %s'):format(row[1], err))
    end
  end

  -- lfs заодно показывает, что каталог загрузчика на месте.
  local lfs = take('lfs')
  if lfs then
    local n = 0
    for _ in lfs.dir(getPaths().scripts) do n = n + 1 end
    log(('[NetProbe] в каталоге скриптов записей: %d'):format(n))
  end
end

-- ═════════════════════════════════════════════════════════════════ main

function main()
  registerChatCommand('tcping', tcping)
  registerChatCommand('dns', dns)
  registerChatCommand('geturl', geturl)
  registerChatCommand('netinfo', netinfo)

  log('[NetProbe] /netinfo, /tcping, /dns, /geturl')
end
