-- HTTP-клиент в духе socket.http из LuaSocket.
--
--   local http = require 'socket.http'
--   local body, code, headers = http.request('https://example.com')
--
--   local body, code, headers = http.request{
--     url     = 'https://api.example.com/v1',
--     method  = 'POST',
--     headers = { ['Content-Type'] = 'application/json' },
--     source  = '{"a":1}',            -- строкой, а не ltn12-источником
--   }
--
-- Отличия от оригинала, чтобы не было сюрпризов:
--   * тело запроса передаётся строкой в source, генераторы ltn12 не нужны;
--   * sink не поддерживается — тело ответа возвращается строкой;
--   * вызывать можно только из main() или lua_thread: внутри стоит wait().

local socket = require 'socket'

local http = {}

http.TIMEOUT = 30000        -- миллисекунды
http.USERAGENT = 'AGLoader'

local function normalize(req)
  if type(req) == 'string' then
    req = { url = req }
  end
  local opts = {
    url     = req.url,
    method  = (req.method or 'GET'):upper(),
    body    = req.source or req.body,
    headers = {},
    timeout = req.timeout or http.TIMEOUT,
  }
  for k, v in pairs(req.headers or {}) do opts.headers[k] = v end
  if not opts.headers['User-Agent'] then
    opts.headers['User-Agent'] = http.USERAGENT
  end
  return opts
end

-- Возвращает тело, код и заголовки — как в LuaSocket.
-- При ошибке: nil и текст причины.
function http.request(req)
  local opts = normalize(req)
  if not opts.url or opts.url == '' then
    return nil, 'не задан адрес'
  end

  local id, err = net.start(opts)
  if not id then return nil, err or 'запрос не начался' end

  local res, why = socket.await(id, opts.timeout)
  if not res then return nil, why end
  return res.body, res.code, res.headers
end

function http.get(url, headers)
  return http.request { url = url, headers = headers }
end

function http.post(url, body, headers)
  return http.request {
    url = url, method = 'POST', source = body, headers = headers,
  }
end

-- Запустить и забрать позже, не дожидаясь.
function http.async(req)
  return net.start(normalize(req))
end

return http
