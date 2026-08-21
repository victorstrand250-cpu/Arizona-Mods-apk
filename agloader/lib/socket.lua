-- LuaSocket для AGLoader.
--
-- Это настоящий LuaSocket: нативная часть (socket.core) собрана прямо в
-- загрузчик, поэтому доступны и сырые сокеты TCP с UDP, и select, и всё
-- остальное, чего раньше не было.
--
--   local socket = require 'socket'
--   local c = socket.tcp()
--   c:settimeout(2)
--   c:connect('example.com', 80)
--
-- Две поправки к оригиналу, обе из-за того, что скрипты крутятся на потоке
-- отрисовки:
--
--   * socket.sleep не усыпляет поток, а отдаёт управление через wait() —
--     иначе игра замирала бы на всё время сна;
--   * socket.gettime берётся у самого LuaSocket, но если нативная часть
--     почему-то не поднялась, остаётся os.clock.
--
-- Для HTTP лучше брать socket.http: он ходит системным стеком Android
-- фоновым потоком и не держит кадр. Сырые сокеты здесь блокирующие, и
-- длинный connect подвесит игру — ставьте settimeout.

local socket = require 'socket.upstream'

-- Сон без остановки кадра.
local nativeSleep = socket.sleep
function socket.sleep(sec)
  local ms = (tonumber(sec) or 0) * 1000
  if type(wait) == 'function' then
    wait(ms)
  elseif nativeSleep then
    nativeSleep(sec)
  end
end

if type(socket.gettime) ~= 'function' then
  function socket.gettime() return os.clock() end
end

-- Асинхронные запросы загрузчика: их ждёт socket.http, но иногда удобнее
-- дёрнуть напрямую и забрать ответ позже.
function socket.async(opts) return net.start(opts) end
function socket.poll(id) return net.poll(id) end

function socket.result(id)
  local res = net.result(id)
  if res then net.release(id) end
  return res
end

function socket.pending() return net.pending() end

-- Ожидание ответа фонового запроса. Вынесено сюда, потому что им
-- пользуются и socket.http, и requests.
local POLL_MS = 25

local function inCoroutine()
  local co, isMain = coroutine.running()
  if isMain == nil then return co ~= nil end
  return not isMain
end

function socket.await(id, timeout_ms)
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

return socket
