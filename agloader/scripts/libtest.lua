-- Проверка всех библиотек загрузчика: /libtest
--
-- Каждая строка — отдельная проверка, которая либо проходит, либо
-- показывает, на чём споткнулась. Сетевые проверки идут отдельной кнопкой:
-- они ходят наружу и занимают время.

script_name('LibTest')
script_author('AGLoader')
script_version('1.0')

local MDS = 1
local open = false
local results = {}
local running = false

-- Одна проверка: имя, что вернулось, и почему упало, если упало.
local function check(group, name, fn)
  local ok, res = pcall(fn)
  results[#results + 1] = {
    group = group, name = name,
    ok = ok and res ~= false,
    note = ok and (res ~= true and tostring(res) or '') or tostring(res),
  }
end

-- ═══════════════════════════════════════════════════════════ проверки

local function runLocal()
  results = {}

  -- ── загрузчик ──────────────────────────────────────────────────────
  check('загрузчик', 'версия', function()
    local v = loaderVersion()
    assert(type(v) == 'string' and #v > 0, 'пусто')
    return v
  end)
  check('загрузчик', 'экран', function()
    local w, h = getScreenSize()
    assert(w and w > 0 and h and h > 0, 'нулевой размер')
    return ('%dx%d, масштаб %.2f'):format(w, h, getUiScale())
  end)
  check('загрузчик', 'каталоги', function()
    local p = getPaths()
    assert(doesDirectoryExist(p.scripts), 'нет каталога скриптов')
    assert(doesDirectoryExist(p.config), 'нет каталога настроек')
    return p.scripts
  end)
  check('загрузчик', 'файлы', function()
    local f = assert(io.open(getPaths().config .. '/libtest.tmp', 'w'))
    f:write('проверка')
    f:close()
    local g = assert(io.open(getPaths().config .. '/libtest.tmp', 'r'))
    local body = g:read('*a')
    g:close()
    deleteFile(getPaths().config .. '/libtest.tmp')
    assert(body == 'проверка', 'прочиталось не то')
    return true
  end)
  check('загрузчик', 'script.this', function()
    assert(script and script.this, 'нет script.this')
    return script.this.name
  end)
  check('загрузчик', 'lua_thread', function()
    local hit = false
    local t = lua_thread.create(function() hit = true end)
    assert(t, 'поток не создался')
    return 'создан'
  end)

  -- ── память ─────────────────────────────────────────────────────────
  check('память', 'база движка', function()
    local b = memory.getclientbase()
    assert(b and b > 0, 'libag-client.so не найдена')
    return ('0x%X'):format(b)
  end)
  check('память', 'чтение', function()
    local b = memory.getclientbase()
    local head = memory.readbytes(b, 4)
    assert(head and head:byte(1) == 0x7F and head:sub(2, 4) == 'ELF',
           'в начале библиотеки не ELF')
    return 'ELF на месте'
  end)
  check('память', 'readptrs пакетом', function()
    local ag = require 'arizona'
    local addr, count = ag.poolArray(1)
    assert(addr, 'массив сущностей не выделен — мир не прогружен')
    local ptrs = memory.readptrs(addr, count)
    return ('занято %d из %d мест'):format(#ptrs, count)
  end)
  check('память', 'gather пакетом', function()
    local ag = require 'arizona'
    local addr, count = ag.poolArray(1)
    assert(addr, 'массив сущностей не выделен')
    local ptrs = memory.readptrs(addr, count)
    if #ptrs == 0 then return 'пул пуст' end
    local vals, ok = memory.gather(ptrs, ag.OFF_ENT_MODEL, 'i16')
    local good = 0
    for i = 1, #ptrs do if ok[i] then good = good + 1 end end
    return ('прочиталось %d из %d'):format(good, #ptrs)
  end)
  check('память', 'области', function()
    local r = memory.regions()
    assert(r and #r > 0, 'список областей пуст')
    return ('%d областей'):format(#r)
  end)

  -- ── движок ─────────────────────────────────────────────────────────
  local ag = require 'arizona'
  check('движок', 'свой слот', function()
    local i = ag.localIndex()
    assert(i, 'слот не определён — вы ещё не в игре')
    return ('слот %d'):format(i)
  end)
  check('движок', 'координаты', function()
    local me = assert(ag.localPlayer(), 'игрок не найден')
    local x, y, z = ag.position(me)
    assert(x, 'позиция не читается')
    return ('%.1f %.1f %.1f'):format(x, y, z)
  end)
  check('движок', 'скорость', function()
    local me = assert(ag.localPlayer(), 'игрок не найден')
    return ('%.1f км/ч'):format(ag.speedKmh(me) or 0)
  end)
  check('движок', 'список игроков', function()
    local p = ag.players()
    return ('%d в массиве'):format(#p)
  end)
  check('движок', 'пулы сущностей', function()
    local parts = {}
    for n = 1, #ag.POOLS do
      local addr, count, name = ag.poolArray(n)
      if addr then
        local ptrs = memory.readptrs(addr, count)
        parts[#parts + 1] = ('%s %d/%d'):format(name, #ptrs, count)
      else
        parts[#parts + 1] = ('%s нет'):format(ag.POOLS[n].name)
      end
    end
    return table.concat(parts, ', ')
  end)
  check('движок', 'сущности вокруг', function()
    local me = assert(ag.localPlayer(), 'игрок не найден')
    local x, y, z = ag.position(me)
    assert(x, 'позиция не читается')
    local o = ag.entities({ near = { x, y, z }, radius = 200 })
    assert(#o > 0, 'вокруг игрока пусто — смещение позиции неверное')
    local near = o[1]
    for _, e in ipairs(o) do if e.dist < near.dist then near = e end end
    return ('%d в 200 м, ближайшая модель %d в %.1f м')
           :format(#o, near.model or -1, near.dist)
  end)
  check('движок', 'описание модели', function()
    local me = assert(ag.localPlayer(), 'игрок не найден')
    local x, y, z = ag.position(me)
    local o = ag.entities({ near = { x, y, z }, radius = 200, max = 50 })
    assert(#o > 0, 'вокруг пусто')
    for _, e in ipairs(o) do
      local mi, t = ag.modelInfo(e.model)
      if mi then return ('модель %d, тип %d'):format(e.model, t or -1) end
    end
    error('ни одно описание модели не прочиталось')
  end)
  check('движок', 'камера', function()
    ag.loadProjection()
    assert(ag.cam.addr ~= 0, 'не найдена — /recon → «Найти камеру»')
    local m = ag.cameraMatrix()
    assert(m, 'адрес есть, но матрица не читается')
    return ('0x%X, поле зрения %d°'):format(ag.cam.addr, ag.cam.fov)
  end)

  -- ── библиотеки ─────────────────────────────────────────────────────
  check('json', 'разбор и сборка', function()
    local json = require 'json'
    local t = json.decode('{"a":[1,2,3],"b":"текст","c":true,"d":null}')
    assert(t.a[2] == 2 and t.b == 'текст' and t.c == true, 'разобралось не так')
    local s = json.encode({ x = 1, y = { 'а', 'б' } })
    local back = json.decode(s)
    assert(back.y[2] == 'б', 'обратно не собралось')
    return s
  end)
  check('json', 'ошибка вместо падения', function()
    local json = require 'json'
    local t, err = json.decode('{сломано}')
    assert(t == nil and type(err) == 'string', 'битый json не дал ошибку')
    return err
  end)
  check('encoding', 'CP1251 в UTF-8', function()
    local encoding = require 'encoding'
    encoding.default = 'CP1251'
    local u8 = encoding.UTF8
    -- 'Камень' в CP1251.
    local cp = string.char(0xCA, 0xE0, 0xEC, 0xE5, 0xED, 0xFC)
    local utf = u8(cp)
    assert(utf == 'Камень', 'вышло: ' .. utf)
    assert(u8:decode(utf) == cp, 'обратно не сошлось')
    return utf
  end)
  check('inicfg', 'сохранить и прочитать', function()
    local inicfg = require 'inicfg'
    local data = { ['блок'] = { ['число'] = 42, ['текст'] = 'привет' } }
    assert(inicfg.save(data, 'libtest.ini'), 'не сохранился')
    local back = inicfg.load(nil, 'libtest.ini')
    assert(back and back['блок'], 'блок не прочитался')
    assert(tonumber(back['блок']['число']) == 42, 'число потерялось')
    deleteFile(getPaths().config .. '/libtest.ini')
    return 'ini цел'
  end)
  check('jsoncfg', 'сохранить и прочитать', function()
    local jsoncfg = require 'jsoncfg'
    assert(jsoncfg.save({ a = 1, b = 'два' }, 'libtest'), 'не сохранился')
    local back = jsoncfg.load({}, 'libtest')
    assert(back.b == 'два', 'значение потерялось')
    return 'json-конфиг цел'
  end)
  check('base64', 'туда и обратно', function()
    local b64 = require 'base64'
    local enc = b64.encode('AGLoader')
    assert(b64.decode(enc) == 'AGLoader', 'обратно не сошлось')
    return enc
  end)
  check('md5', 'известная сумма', function()
    local md5 = require 'md5'
    local h = md5.sumhexa and md5.sumhexa('abc') or md5.sum('abc')
    assert(h == '900150983cd24fb0d6963f7d28e17f72', 'сумма другая: ' .. tostring(h))
    return h
  end)
  check('sha1', 'известная сумма', function()
    local sha1 = require 'sha1'
    local h = sha1.sha1('abc')
    assert(h == 'a9993e364706816aba3e25717850c26c9cd0d89d',
           'сумма другая: ' .. tostring(h))
    return h
  end)
  check('vector3d', 'арифметика', function()
    local v3 = require 'vector3d'
    local a, b = v3(1, 2, 3), v3(4, 5, 6)
    local c = a + b
    assert(c.x == 5 and c.y == 7 and c.z == 9, 'сложение не сошлось')
    return ('длина %.3f'):format(a:length())
  end)
  check('matrix3x3', 'загружается', function()
    local m = require 'matrix3x3'
    assert(type(m) == 'table' or type(m) == 'function', 'не таблица')
    return 'ок'
  end)
  check('binaryheap', 'порядок', function()
    local heap = require 'binaryheap'
    local h = heap.minUnique()
    h:insert(5, 'пять'); h:insert(1, 'один'); h:insert(3, 'три')
    -- minUnique отдаёт сначала полезную нагрузку, потом её вес.
    local first = h:pop()
    assert(first == 'один', 'наверху оказалось: ' .. tostring(first))
    return 'мин-куча работает'
  end)
  check('timerwheel', 'загружается', function()
    local tw = require 'timerwheel'
    assert(type(tw) == 'table', 'не таблица')
    return 'ок'
  end)
  check('ltn12', 'фильтр', function()
    local ltn12 = require 'ltn12'
    local out = {}
    -- sink.table отдаёт два значения, а третий аргумент pump.all — это шаг,
    -- поэтому лишнее приходится отсекать скобками.
    ltn12.pump.all(ltn12.source.string('привет'), (ltn12.sink.table(out)))
    assert(table.concat(out) == 'привет', 'через насос прошло не то')
    return 'ок'
  end)
  check('moonloader', 'константы', function()
    local ml = require 'moonloader'
    assert(type(ml) == 'table', 'не таблица')
    return 'ок'
  end)
  check('пролог', 'encodeJson/decodeJson', function()
    local s = encodeJson({ a = 1 })
    assert(decodeJson(s).a == 1, 'обратно не сошлось')
    return s
  end)
  check('пролог', 'расстояния и округление', function()
    assert(getDistanceBetweenCoords3d(0, 0, 0, 3, 4, 0) == 5, 'считает неверно')
    assert(round(1.2345, 2) == 1.23, 'округляет неверно')
    assert(stripColorCodes('{FF0000}текст') == 'текст', 'коды не сняты')
    return 'ок'
  end)
end

-- Сеть отдельно: ходит наружу и должна работать из корутины.
local function runNet()
  check('сеть', 'HTTPS GET', function()
    local requests = require 'requests'
    local r = requests.get('https://httpbin.org/get')
    assert(r, 'ничего не вернулось')
    assert(not r.error, tostring(r.error))
    assert(r.status_code == 200, 'код ' .. tostring(r.status_code))
    return ('%d, тело %d байт'):format(r.status_code, #(r.text or ''))
  end)
  check('сеть', 'JSON ответа', function()
    local requests = require 'requests'
    local r = requests.get('https://httpbin.org/json')
    assert(r and not r.error, tostring(r and r.error))
    local t = r.json()
    assert(type(t) == 'table', 'ответ не разобрался')
    return 'разобрался'
  end)
  check('сеть', 'POST с телом', function()
    local requests = require 'requests'
    local r = requests.post('https://httpbin.org/post',
                            { json = { ['привет'] = 'мир' } })
    assert(r and not r.error, tostring(r and r.error))
    assert(r.status_code == 200, 'код ' .. tostring(r.status_code))
    return 'отправилось'
  end)
  check('сеть', 'socket.http', function()
    local http = require 'socket.http'
    local body, code = http.request('https://example.com')
    assert(code == 200, 'код ' .. tostring(code))
    assert(body and #body > 0, 'пустое тело')
    return ('%d байт'):format(#body)
  end)
  check('сеть', 'разбор адреса', function()
    local url = require 'socket.url'
    local p = url.parse('https://user@host.tld:8080/путь?a=1#я')
    assert(p.host == 'host.tld' and p.port == '8080', 'разобрало неверно')
    return p.host .. ':' .. p.port
  end)
end

-- ═══════════════════════════════════════════════════════════ интерфейс

function onImgui()
  local s = getUiScale()
  if s and s > 0 then MDS = s end
  if not open then return end

  local sw, sh = getScreenSize()
  imgui.SetNextWindowSize(560 * MDS, 460 * MDS, imgui.Cond_Always)
  imgui.SetNextWindowPos(sw / 2 - 280 * MDS, sh / 2 - 230 * MDS,
                         imgui.Cond_FirstUseEver)

  local visible, o = imgui.Begin('Проверка библиотек', open,
                                 imgui.WindowFlags_NoResize)
  open = o

  if visible then
    local passed, failed = 0, 0
    for _, r in ipairs(results) do
      if r.ok then passed = passed + 1 else failed = failed + 1 end
    end

    if imgui.Button('Прогнать заново', 180 * MDS, 30 * MDS) then
      lua_thread.create(runLocal)
    end
    imgui.SameLine()
    if imgui.Button(running and 'Сеть идёт…' or 'Проверить сеть',
                    180 * MDS, 30 * MDS) and not running then
      lua_thread.create(function()
        running = true
        runNet()
        running = false
      end)
    end
    imgui.SameLine()
    imgui.TextColored(('%d из %d'):format(passed, passed + failed),
                      failed == 0 and 0.30 or 1.00,
                      failed == 0 and 0.90 or 0.60, 0.45, 1)

    imgui.Separator()

    if imgui.BeginChild('##list', 540 * MDS, 370 * MDS, false) then
      local lastGroup
      for _, r in ipairs(results) do
        if r.group ~= lastGroup then
          lastGroup = r.group
          imgui.Spacing()
          imgui.TextColored(r.group, 0.55, 0.60, 0.75, 1)
          imgui.Separator()
        end
        if r.ok then
          imgui.TextColored('OK', 0.30, 0.90, 0.45, 1)
        else
          imgui.TextColored('--', 1.00, 0.40, 0.30, 1)
        end
        imgui.SameLine(40 * MDS)
        imgui.Text(r.name)
        imgui.SameLine(210 * MDS)
        if r.ok then
          imgui.TextDisabled(r.note)
        else
          imgui.TextColored(r.note, 1.00, 0.65, 0.40, 1)
        end
      end
    end
    imgui.EndChild()
  end
  imgui.End()
end

-- ═════════════════════════════════════════════════════════════════ main

function main()
  registerChatCommand('libtest', function()
    open = not open
    if open and #results == 0 then lua_thread.create(runLocal) end
  end)

  log('[LibTest] /libtest — проверка всех библиотек')

  -- Первый прогон сразу в лог: так видно результат, даже не открывая окно.
  wait(2000)
  runLocal()
  local passed, failed = 0, 0
  for _, r in ipairs(results) do
    if r.ok then passed = passed + 1
    else
      failed = failed + 1
      log(('[LibTest] %s / %s — %s'):format(r.group, r.name, r.note))
    end
  end
  log(('[LibTest] прошло %d, не прошло %d'):format(passed, failed))
end
