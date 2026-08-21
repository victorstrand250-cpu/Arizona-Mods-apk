-- Время суток и освещение.
--
--   /time          меню
--   /time 3        поставить три часа ночи
--   /time 21 30    полдесятого вечера
--   /timefreeze    остановить или пустить часы
--
-- Часы движка найдены разбором кода: их читает та самая функция, что
-- смешивает две точки суток в таймцикле. Меняем их — меняется освещение,
-- небо, туман и дальность прорисовки, потому что всё это движок берёт из
-- таймцикла по текущему часу.
--
-- Это клиентская картинка. Сервер своё время не меняет и при случае
-- пришлёт его обратно — тогда просто поставьте заново.

script_name('WorldTime')
script_author('AGLoader')
script_version('1.0')

local ag = require 'arizona'

local MDS = 1
local open = false
local frozen = false
local savedSpeed = 1000

-- Восемь точек, между которыми движок и смешивает освещение.
local SLOTS = { 0, 3, 6, 9, 12, 15, 18, 21 }

local function applyTime(h, m)
  if ag.setTime(h, m) then
    notify(('[WorldTime] %02d:%02d'):format(h, m or 0), 3)
  else
    notify('[WorldTime] не записалось — игра ещё не в мире', 4)
  end
end

local function toggleFreeze()
  if frozen then
    ag.setTimeSpeed(savedSpeed)
    frozen = false
    notify('[WorldTime] часы пущены', 3)
  else
    savedSpeed = ag.timeSpeed() or 1000
    if savedSpeed <= 0 then savedSpeed = 1000 end
    ag.setTimeSpeed(0)
    frozen = true
    notify('[WorldTime] часы остановлены', 3)
  end
end

function onImgui()
  local s = getUiScale()
  if s and s > 0 then MDS = s end
  if not open then return end

  imgui.SetNextWindowSize(420 * MDS, 0, imgui.Cond_Always)
  local visible, o = imgui.Begin('Время суток', open,
    imgui.WindowFlags_NoResize + imgui.WindowFlags_AlwaysAutoResize)
  open = o

  if visible then
    local h, m, sec = ag.time()
    if not h then
      imgui.TextColored('Часы не читаются — вы ещё не в мире',
                        1.0, 0.45, 0.3, 1)
    else
      imgui.TextColored(('Сейчас %02d:%02d:%02d'):format(h, m, sec),
                        0.3, 0.95, 0.45, 1)

      imgui.SetNextItemWidth(260 * MDS)
      local ch, v = imgui.SliderInt('Час', h, 0, 23, ('%d ч'):format(h))
      if ch then applyTime(v, m) end

      imgui.SetNextItemWidth(260 * MDS)
      ch, v = imgui.SliderInt('Минута', m, 0, 59, ('%d мин'):format(m))
      if ch then applyTime(h, v) end

      imgui.Separator()
      imgui.TextDisabled('Точки таймцикла — между ними движок и смешивает')
      for i, slot in ipairs(SLOTS) do
        if i > 1 then imgui.SameLine(0, 4 * MDS) end
        if imgui.Button(('%02d:00'):format(slot), 46 * MDS, 30 * MDS) then
          applyTime(slot, 0)
        end
      end

      imgui.Separator()
      local speed = ag.timeSpeed() or 0
      imgui.Text(('Игровая минута идёт %d мс'):format(speed))
      imgui.SetNextItemWidth(260 * MDS)
      ch, v = imgui.SliderInt('Скорость', speed, 0, 10000,
                              speed == 0 and 'стоп' or ('%d мс'):format(speed))
      if ch then ag.setTimeSpeed(v); frozen = (v == 0) end

      if imgui.Button(frozen and 'Пустить часы' or 'Остановить часы',
                      400 * MDS, 34 * MDS) then
        toggleFreeze()
      end

      imgui.Separator()
      imgui.TextDisabled('Молния поднимает яркость всей сцены')
      if imgui.Button('Вспышка', 400 * MDS, 30 * MDS) then
        lua_thread.create(function()
          ag.lightning(64)
          wait(120)
          ag.lightning(0)
        end)
      end
    end
  end
  imgui.End()
end

function main()
  registerChatCommand('time', function(arg)
    arg = tostring(arg or ''):match('^%s*(.-)%s*$')
    if arg == '' then open = not open; return end
    local h, m = arg:match('^(%d+)%s*(%d*)$')
    if not h then
      notify('[WorldTime] /time [час] [минута]', 4)
      return
    end
    applyTime(tonumber(h), tonumber(m) or 0)
  end)

  registerChatCommand('timefreeze', toggleFreeze)

  log('[WorldTime] /time — меню и установка часа, /timefreeze — стоп-часы')
end
