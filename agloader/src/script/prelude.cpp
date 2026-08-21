// SPDX-License-Identifier: GPL-3.0-or-later
//
// Пролог выполняется в каждом lua_State до кода самого скрипта и доносит то,
// что скрипты MonetLoader и MoonLoader считают данностью: свои корутины
// (lua_thread), привычные имена функций и мелкие удобства. Всё это чистый
// Lua поверх уже имеющегося API, поэтому и живёт отдельным файлом, а не
// растёт в биндингах.
#include "script/prelude.h"

namespace ag::script {

const char* prelude_source()
{
  return R"LUA(
-- ─────────────────────────────────────────────────────────── lua_thread
--
-- Скрипты MoonLoader вовсю пользуются lua_thread.create: фоновые корутины,
-- которые сами засыпают через wait(). Загрузчик крутит только main(),
-- поэтому планировщик для остальных живёт здесь. wait() внутри такой
-- корутины отдаёт наружу число миллисекунд — ровно как в main().

local threads = {}
local thread_mt = {}
thread_mt.__index = thread_mt

function thread_mt:terminate()
  self.dead = true
  self.co = nil
end

function thread_mt:status()
  if self.dead then return 'dead' end
  if not self.co then return 'dead' end
  return coroutine.status(self.co)
end

function thread_mt:run(...)
  if self.dead or self.started then return end
  self.started = true
  self.args = { ... }
end

lua_thread = {}

function lua_thread.create(fn, ...)
  local t = setmetatable({
    co      = coroutine.create(fn),
    wake_at = 0,
    dead    = false,
    started = true,
    args    = { ... },
  }, thread_mt)
  threads[#threads + 1] = t
  return t
end

function lua_thread.create_suspended(fn)
  local t = setmetatable({
    co      = coroutine.create(fn),
    wake_at = 0,
    dead    = false,
    started = false,
    args    = {},
  }, thread_mt)
  threads[#threads + 1] = t
  return t
end

-- Загрузчик зовёт это каждый кадр, до onFrame.
function __agloader_tick(dt)
  if #threads == 0 then return end

  local now = os.clock() * 1000
  local alive = {}

  for i = 1, #threads do
    local t = threads[i]
    if not t.dead and t.co and t.started and now >= t.wake_at then
      local args = t.args
      t.args = nil
      local ok, res
      if args then
        ok, res = coroutine.resume(t.co, unpack(args))
      else
        ok, res = coroutine.resume(t.co)
      end

      if not ok then
        -- Упавшая фоновая корутина не должна валить весь скрипт: пишем
        -- в лог и хороним только её.
        log('ошибка в lua_thread: ' .. tostring(res))
        t.dead = true
      elseif coroutine.status(t.co) == 'dead' then
        t.dead = true
      else
        -- wait() отдал число миллисекунд. Отрицательное — спать вечно.
        local ms = tonumber(res) or 0
        if ms < 0 then
          t.wake_at = math.huge
        else
          t.wake_at = now + ms
        end
      end
    end
    if not t.dead then
      alive[#alive + 1] = t
    end
  end

  threads = alive
end

-- ──────────────────────────────────────────────── привычные имена

-- Много где встречается именно это написание.
function getScreenResolution()
  return getScreenSize()
end

function getGameDirectory()
  return getWorkingDirectory()
end

-- В MoonLoader это каталог со скриптом. У нас скрипты лежат в одном месте.
function getScriptDirectory()
  return getPaths().scripts
end

function getConfigDirectory()
  return getPaths().config
end

-- ───────────────────────────────────────────────────── мелочи

-- print у скриптов должен попадать в лог загрузчика, а не в никуда.
-- log приходит из загрузчика нативным, так что рекурсии тут быть не может,
-- но если его вдруг нет — остаёмся на исходном print.
local _print = print
local _log = log
if type(_log) == 'function' then
  function print(...)
    local parts = {}
    for i = 1, select('#', ...) do
      parts[#parts + 1] = tostring((select(i, ...)))
    end
    _log(table.concat(parts, '\t'))
  end
end

-- Цветовые коды вида {FFFFFF} из чата SA-MP. В новом движке чата для нас
-- нет, поэтому текст просто уходит в лог — но уже без разметки.
function stripColorCodes(text)
  return (tostring(text):gsub('{%x%x%x%x%x%x}', ''))
end

-- Часто встречающаяся мелочь: округление до знаков.
function round(num, places)
  local mult = 10 ^ (places or 0)
  return math.floor(num * mult + 0.5) / mult
end

-- ───────────────────────────────── привычные глобали MoonLoader

-- Библиотеки MoonLoader (jsoncfg и подобные) обращаются к script.this и к
-- encodeJson/decodeJson как к чему-то, что есть всегда. Даём то же самое,
-- иначе они падают на первой же строке.
script = script or {}

do
  local info = thisScript and thisScript() or nil
  script.this = info or { name = '?', filename = '?', path = '?',
                          version = '?', author = '?', id = 0 }
  -- В MoonLoader script.this.filename — имя файла без пути.
  script.this.filename = (script.this.filename or '?')
                         :match('([^/\\]+)$') or script.this.filename
  script.this.name = script.this.name or script.this.filename
end

function encodeJson(value, pretty)
  return require('json').encode(value, pretty)
end

function decodeJson(text)
  local ok, res = pcall(function() return require('json').decode(text) end)
  if not ok then error(res, 2) end
  if res == nil then error('json: не разобрать', 2) end
  return res
end

-- MoonLoader: отложенный вызов внутри корутины.
function setTimer(ms, fn, ...)
  local args = { ... }
  return lua_thread.create(function()
    wait(ms)
    fn(unpack(args))
  end)
end

-- Расстояние между точками — есть почти в каждом скрипте.
function getDistanceBetweenCoords3d(x1, y1, z1, x2, y2, z2)
  local dx, dy, dz = x1 - x2, y1 - y2, z1 - z2
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function getDistanceBetweenCoords2d(x1, y1, x2, y2)
  local dx, dy = x1 - x2, y1 - y2
  return math.sqrt(dx * dx + dy * dy)
end
)LUA";
}

}  // namespace ag::script
