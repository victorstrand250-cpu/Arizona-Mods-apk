-- Прогон всех скриптов на обычном lua5.1: загрузить, отрисовать кадр,
-- вызвать каждую чат-команду. Игры здесь нет, поэтому всё, что читает
-- память, возвращает nil — скрипт обязан это пережить, а не упасть.
local env = dofile((os.getenv('AGL_TEST') or '.') .. '/stubs.lua')
dofile(arg[1])                       -- пролог загрузчика, вынутый из prelude.cpp

local root = env.root
local bad = 0
local fileBad = 0

local list = {}
local p = io.popen('ls ' .. root .. '/scripts/*.lua')
for line in p:lines() do list[#list + 1] = line end
p:close()

for _, file in ipairs(list) do
  local short = file:match('([^/]+)$')
  fileBad = bad
  local chunk, err = loadfile(file)
  if not chunk then
    bad = bad + 1
    io.write(('  %-28s ЗАГРУЗКА: %s\n'):format(short, err))
  else
    local ok, e = pcall(chunk)
    if not ok then
      bad = bad + 1
      io.write(('  %-28s ВЫПОЛНЕНИЕ: %s\n'):format(short, e))
    else
      if type(onImgui) == 'function' then
        local ok2, e2 = pcall(onImgui)
        if not ok2 then
          bad = bad + 1
          io.write(('  %-28s onImgui: %s\n'):format(short, e2))
        end
      end
      -- Отдельная проверка onTouch. В загрузчике, как и в MoonLoader,
      -- явный false означает «касание поглощено»: скрипт, который вернул
      -- его на обычное событие, отбирает у игры весь ввод — ни идти, ни
      -- чат открыть. Со стороны это выглядит как зависшая игра, поэтому
      -- ловим здесь, а не на телефоне.
      if type(onTouch) == 'function' then
        for _, act in ipairs({ 0, 2, 1 }) do
          local ok4, res = pcall(onTouch, act, 0, 100, 200)
          if not ok4 then
            bad = bad + 1
            io.write(('  %-28s onTouch(%d): %s\n'):format(short, act, res))
          elseif res == false then
            bad = bad + 1
            io.write(('  %-28s onTouch(%d) вернул false — это поглощает '
                      .. 'касание, игра его не увидит\n'):format(short, act))
          end
        end
      end

      for name, fn in pairs(env.cmds) do
        local ok3, e3 = pcall(fn, '')
        if not ok3 then
          bad = bad + 1
          io.write(('  %-28s /%s: %s\n'):format(short, name, e3))
        end
      end
      if bad == fileBad then io.write(('  %-28s ok\n'):format(short)) end
    end
    onImgui, onFrame, onTouch, onKey = nil, nil, nil, nil
    onPause, onResume, onScriptTerminate, main = nil, nil, nil, nil
    for k in pairs(env.cmds) do env.cmds[k] = nil end
  end
end

os.exit(bad == 0 and 0 or 1)
