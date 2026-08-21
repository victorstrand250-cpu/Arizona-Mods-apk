-- requests для AGLoader — тот же вид вызова, что у библиотеки MonetLoader.
--
--   local requests = require 'requests'
--
--   local r = requests.get('https://api.example.com/data')
--   if r.status_code == 200 then
--     print(r.text)
--     local t = r.json()
--   end
--
--   requests.post('https://api.example.com/send', {
--     data = { text = 'привет' },        -- уйдёт как форма
--   })
--   requests.post('https://api.example.com/send', {
--     json = { text = 'привет' },        -- уйдёт как JSON
--   })
--
-- Вызывать только из main() или lua_thread: внутри стоит ожидание.
-- Оригинал ронял исключение при сетевой ошибке; здесь возвращается таблица
-- с полем error, а status_code равен нулю — проверять проще, а скрипт от
-- отвалившегося интернета не падает.

local http = require 'socket.http'
local url  = require 'socket.url'
local json = require 'json'

local requests = {}

requests.timeout = 30000

local function buildResponse(body, code, headers, err)
  local r = {
    status_code = code or 0,
    text        = body or '',
    content     = body or '',
    headers     = headers or {},
    error       = err,
    ok          = (code ~= nil and code >= 200 and code < 300),
  }

  function r.json()
    local value, why = json.decode(r.text)
    if value == nil then return nil, why end
    return value
  end

  return r
end

local function perform(method, address, opts)
  opts = opts or {}
  local headers = {}
  for k, v in pairs(opts.headers or {}) do headers[k] = v end

  local body = opts.body

  if opts.json ~= nil then
    body = json.encode(opts.json)
    headers['Content-Type'] = headers['Content-Type'] or 'application/json'
  elseif type(opts.data) == 'table' then
    body = url.buildquery(opts.data)
    headers['Content-Type'] = headers['Content-Type']
                              or 'application/x-www-form-urlencoded'
  elseif type(opts.data) == 'string' then
    body = opts.data
  end

  -- Параметры в адресной строке.
  if type(opts.params) == 'table' and next(opts.params) then
    local q = url.buildquery(opts.params)
    address = address .. (address:find('?', 1, true) and '&' or '?') .. q
  end

  local text, code, resHeaders = http.request {
    url     = address,
    method  = method,
    source  = body,
    headers = headers,
    timeout = opts.timeout or requests.timeout,
  }

  if not text then
    -- Здесь code — это текст причины: так устроен ответ socket.http.
    return buildResponse(nil, nil, nil, code)
  end
  return buildResponse(text, code, resHeaders)
end

function requests.request(method, address, opts)
  return perform((method or 'GET'):upper(), address, opts)
end

function requests.get(address, opts)    return perform('GET', address, opts) end
function requests.post(address, opts)   return perform('POST', address, opts) end
function requests.put(address, opts)    return perform('PUT', address, opts) end
function requests.delete(address, opts) return perform('DELETE', address, opts) end
function requests.head(address, opts)   return perform('HEAD', address, opts) end
function requests.patch(address, opts)  return perform('PATCH', address, opts) end

-- Запустить и забрать позже — когда ждать ответ незачем.
function requests.async(method, address, opts)
  opts = opts or {}
  return http.async {
    url     = address,
    method  = (method or 'GET'):upper(),
    source  = opts.body or opts.data,
    headers = opts.headers,
    timeout = opts.timeout or requests.timeout,
  }
end

return requests
