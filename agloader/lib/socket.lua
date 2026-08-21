-- Сеть в стиле LuaSocket для AGLoader.
--
-- Настоящий LuaSocket — это C-модуль плюс OpenSSL для HTTPS. Здесь вместо
-- них системный HTTP-стек Android через JNI: у него уже есть TLS, корневые
-- сертификаты и настройки прокси устройства.
--
-- Главное отличие от оригинала: запрос уходит в фоновый поток, а вызов
-- ждёт его в корутине через wait(). Выглядит как блокирующий, но поток
-- отрисовки не держит и игра не подвисает. Поэтому вызывать эти функции
-- можно только из main() или из lua_thread.create — там, где есть wait().
--
--   local http = require('socket.http')
--   local body, code, headers = http.request('https://example.com')
--
--   local body, code = http.request{
--     url = 'https://api.example.com/v1',
--     method = 'POST',
--     headers = { ['Content-Type'] = 'application/json' },
--     source = '{"a":1}',
--   }

local socket = {}

socket._VERSION = 'AGLoader socket (HTTP через системный стек Android)'

-- Сколько ждём между опросами готовности. 25 мс — это примерно два кадра,
-- заметной задержки не даёт, а процессор не жжёт.
local POLL_MS = 25

local function inCoroutine()
  local co, isMain = coroutine.running()
  if isMain == nil then
    -- Lua 5.1: coroutine.running() возвращает nil в главном потоке.
    return co ~= nil
  end
  return not isMain
end

-- Ждёт завершения запроса. Возвращает таблицу ответа либо nil и причину.
local function await(id, timeout_ms)
  if not id then return nil, 'запрос не начался' end

  local waited = 0
  timeout_ms = timeout_ms or 30000

  while true do
    local st = net.poll(id)
    if st ~= 'running' then break end

    if not inCoroutine() then
      net.release(id)
      return nil, 'сетевой вызов возможен только из main() или lua_thread'
    end
    wait(POLL_MS)
    waited = waited + POLL_MS
    if waited > timeout_ms then
      net.release(id)
      return nil, 'превышено время ожидания'
    end
  end

  local res = net.result(id)
  net.release(id)
  if not res then return nil, 'ответ не получен' end
  if not res.ok then return nil, res.error or 'ошибка запроса' end
  return res
end

socket.await = await

-- Запустить и не ждать: пригодится, когда ответ нужен «когда-нибудь».
function socket.async(opts)
  return net.start(opts)
end

function socket.poll(id)
  return net.poll(id)
end

function socket.result(id)
  local res = net.result(id)
  if res then net.release(id) end
  return res
end

function socket.pending()
  return net.pending()
end

-- В LuaSocket это время с произвольной точки; os.clock подходит.
function socket.gettime()
  return os.clock()
end

function socket.sleep(sec)
  wait((tonumber(sec) or 0) * 1000)
end

return socket
