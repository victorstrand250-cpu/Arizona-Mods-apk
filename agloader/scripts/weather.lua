-- Погода и время суток.
--
--   /weather       меню
--   /time 3        сразу поставить час
--   /timefreeze    остановить или пустить часы
--
-- Про «погоду» в этом движке стоит сказать честно. Отдельной величины
-- «погода» здесь нет: слова weather в библиотеке не встречается вовсе, а
-- таймцикл — это восемь точек суток без деления по погоде. Зато из
-- таймцикла движок берёт всё сразу: свет, небо, туман, дальность
-- прорисовки и постобработку. Поэтому смена погоды здесь — это смена
-- времени суток, и работает она мгновенно.
--
-- Всё, что скрипт трогает, найдено разбором кода, а не подбором:
--   час и минута       +0x113E024 / +0x113E028
--   скорость хода      +0x113E030
--   вспышка молнии     +0x35E4E9C
--   редактор таймцикла +0x35E5028 / +0x35E5024
--
-- А если нужен именно туман погуще или дальность поменьше — для этого у
-- движка есть собственный редактор таймцикла с ползунками на каждый
-- параметр. Кнопка внизу его открывает.

script_name('Weather')
script_author('AGLoader')
script_version('1.0')

local ag = require 'arizona'

local MDS = 1
local open = false
local frozen = false
local savedSpeed = 1000
local storm = false

-- Держать время. Без этого поставленный час живёт долю секунды: его
-- перебивает либо собственный тик мира, либо синхронизация с сервером.
--
-- Так же сделано и в Weather & Time Changer под MonetLoader: там в main()
-- стоит while true do wait(0) ... setTimeOfDay(час, минуту) end — то есть
-- время переписывается каждый кадр, а не изредка. Раз в сто миллисекунд
-- мало: между записями движок успевает прокрутить свой тик, и час мигает.
-- Поэтому здесь запись висит на onFrame — это и есть «каждый кадр».
local hold = false
local holdH, holdM = 0, 0

-- ═══════════════════════════════════════════════════════════════ наборы

-- Каждый набор — это час суток, потому что именно от часа движок и пляшет.
local PRESETS = {
  { name = 'Рассвет',  hour = 6,  note = 'низкое солнце, длинные тени' },
  { name = 'Утро',     hour = 9,  note = 'ровный дневной свет' },
  { name = 'Полдень',  hour = 12, note = 'максимум света и дальности' },
  { name = 'День',     hour = 15, note = 'привычная картинка' },
  { name = 'Закат',    hour = 19, note = 'тёплый свет, длинные тени' },
  { name = 'Сумерки',  hour = 21, note = 'синий час' },
  { name = 'Ночь',     hour = 0,  note = 'фонари и фары' },
  { name = 'Глухая ночь', hour = 3, note = 'темнее некуда' },
}

local function applyTime(h, m, quiet)
  h = math.max(0, math.min(23, math.floor(h or 0)))
  m = math.max(0, math.min(59, math.floor(m or 0)))
  holdH, holdM = h, m
  if not ag.setTime(h, m) then
    if not quiet then
      notify('[Weather] не записалось — вы ещё не в мире', 4)
    end
    return false
  end
  if not quiet then
    notify(('[Weather] %02d:%02d%s'):format(h, m,
           hold and ', держим' or ''), 3)
  end
  return true
end

local function setHold(on)
  hold = on and true or false
  if hold then
    holdH, holdM = ag.time()
    if not holdH then hold = false; return end
  end
end

local function toggleFreeze()
  if frozen then
    ag.setTimeSpeed(savedSpeed)
    frozen = false
    notify('[Weather] часы пущены', 3)
  else
    savedSpeed = ag.timeSpeed() or 1000
    if savedSpeed <= 0 then savedSpeed = 1000 end
    ag.setTimeSpeed(0)
    frozen = true
    notify('[Weather] часы остановлены', 3)
  end
end

-- Гроза: вспышки с неровными паузами, как настоящие.
local function toggleStorm()
  storm = not storm
  if not storm then
    ag.lightning(0)
    notify('[Weather] гроза выключена', 3)
    return
  end
  notify('[Weather] гроза включена', 3)
  lua_thread.create(function()
    while storm do
      wait(math.random(2500, 9000))
      if not storm then break end
      -- Двойная вспышка: одиночная выглядит как сбой картинки.
      for _ = 1, math.random(1, 2) do
        ag.lightning(math.random(40, 90))
        wait(math.random(40, 110))
        ag.lightning(0)
        wait(math.random(60, 160))
      end
    end
    ag.lightning(0)
  end)
end

-- ══════════════════════════════════════════════════════════════ окно

function onImgui()
  local s = getUiScale()
  if s and s > 0 then MDS = s end
  if not open then return end

  imgui.SetNextWindowSize(440 * MDS, 0, imgui.Cond_Always)
  local visible, o = imgui.Begin('Погода и время', open,
    imgui.WindowFlags_NoResize + imgui.WindowFlags_AlwaysAutoResize)
  open = o

  if visible then
    local h, m, sec = ag.time()
    if not h then
      imgui.TextColored('Часы не читаются — вы ещё не в мире',
                        1.0, 0.45, 0.3, 1)
      imgui.End()
      return
    end

    imgui.TextColored(('Сейчас %02d:%02d:%02d'):format(h, m, sec),
                      0.3, 0.95, 0.45, 1)
    imgui.TextDisabled('Свет, небо, туман и дальность движок берёт из часа')
    imgui.Separator()

    -- Наборы в два столбца: так они помещаются без прокрутки.
    for i, p in ipairs(PRESETS) do
      if i % 2 == 0 then imgui.SameLine(0, 6 * MDS) end
      local w = (440 * MDS - 30 * MDS) / 2
      if imgui.Button(('%s\n%02d:00'):format(p.name, p.hour), w, 40 * MDS) then
        hold = true
        applyTime(p.hour, 0)
      end
    end

    imgui.Spacing()
    imgui.Separator()

    imgui.SetNextItemWidth(280 * MDS)
    local ch, v = imgui.SliderInt('Час', h, 0, 23, ('%d ч'):format(h))
    if ch then applyTime(v, m) end

    imgui.SetNextItemWidth(280 * MDS)
    ch, v = imgui.SliderInt('Минута', m, 0, 59, ('%d мин'):format(m))
    if ch then applyTime(h, v) end

    local speed = ag.timeSpeed() or 0
    imgui.SetNextItemWidth(280 * MDS)
    ch, v = imgui.SliderInt('Минута идёт', speed, 0, 10000,
                            speed == 0 and 'часы стоят' or ('%d мс'):format(speed))
    if ch then ag.setTimeSpeed(v); frozen = (v == 0) end

    if imgui.Button(frozen and 'Пустить часы' or 'Остановить часы',
                    420 * MDS, 32 * MDS) then
      toggleFreeze()
    end

    local ch2, v2 = imgui.Checkbox('Держать время', hold)
    if ch2 then setHold(v2) end
    imgui.SameLine()
    imgui.TextDisabled(hold and ('%02d:%02d'):format(holdH, holdM)
                             or 'иначе час живёт долю секунды')

    imgui.Separator()

    if storm then
      imgui.PushStyleColor(imgui.Col_Button, 0.55, 0.45, 0.05, 1)
    end
    if imgui.Button(storm and 'Гроза идёт — выключить' or 'Гроза',
                    420 * MDS, 34 * MDS) then
      toggleStorm()
    end
    if storm then imgui.PopStyleColor() end
    imgui.TextDisabled('Вспышки поднимают яркость всей сцены')

    imgui.Separator()
    imgui.TextWrapped(
      'Отдельной «погоды» в движке нет: таймцикл — восемь точек суток без ' ..
      'деления по погоде. Если нужен туман погуще или дальность поменьше, ' ..
      'у движка есть свой редактор таймцикла — ползунок на каждый ' ..
      'параметр, включая FogStart и DrawDistance.')

    local editorOn = ag.timecycleEditor()
    if imgui.Button(editorOn and 'Закрыть редактор движка'
                              or 'Открыть редактор таймцикла движка',
                    420 * MDS, 34 * MDS) then
      ag.timecycleEditor(not editorOn)
    end
    if editorOn then
      imgui.TextDisabled(('редактор открыт, точка суток %d')
                         :format(ag.timecycleSlot() or 0))
    end
  end
  imgui.End()
end

-- ═════════════════════════════════════════════════════════════════ main

function main()
  registerChatCommand('weather', function() open = not open end)

  registerChatCommand('time', function(arg)
    arg = tostring(arg or ''):match('^%s*(.-)%s*$')
    if arg == '' then open = not open; return end
    local h, m = arg:match('^(%d+)%s*(%d*)$')
    if not h then
      notify('[Weather] /time [час] [минута]', 4)
      return
    end
    -- Из чата время ставят, чтобы оно осталось, а не мигнуло.
    hold = true
    applyTime(tonumber(h), tonumber(m) or 0)
  end)

  registerChatCommand('timefreeze', toggleFreeze)
  registerChatCommand('storm', toggleStorm)

  registerChatCommand('timehold', function()
    setHold(not hold)
    notify('[Weather] держание времени ' ..
           (hold and 'включено' or 'выключено'), 3)
  end)

  log('[Weather] /weather — меню, /time <час>, /timefreeze, /timehold, /storm')

  -- Здесь ждать нечего: держание висит на onFrame, а этот цикл нужен
  -- только чтобы корутина скрипта жила.
  while true do wait(1000) end
end

-- Каждый кадр, пока держание включено. Две записи по байту — на кадре это
-- не сказывается, зато час не мигает.
function onFrame()
  if hold then
    ag.setTime(holdH, holdM)
  end
end

function onScriptTerminate()
  storm = false
  hold = false
  ag.lightning(0)
end
