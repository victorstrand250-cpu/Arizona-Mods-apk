-- Оверлей поверх игры: рисуется всегда, окна не нужны.
-- Показывает, как пользоваться imgui.Draw* (это foreground draw list,
-- он рисуется поверх всего, включая меню самой игры).

script_name('Overlay')
script_author('agloader')
script_version('1.0')

local enabled = true
local fps, acc, frames = 0, 0, 0

function onFrame(dt)
  acc = acc + dt
  frames = frames + 1
  if acc >= 0.5 then
    fps = frames / acc
    acc, frames = 0, 0
  end
end

function onImgui()
  if not enabled then return end

  local w, h = getScreenSize()
  local line = ('AGLoader %s | %.0f FPS | %dx%d'):format(loaderVersion(), fps, w, h)

  local tw, th = imgui.CalcTextSize(line)
  local x, y = w - tw - 24, 16

  imgui.DrawRectFilled(x - 8, y - 4, x + tw + 8, y + th + 4, 0, 0, 0, 0.55)
  imgui.DrawText(x, y, line, 0.4, 1.0, 0.6, 1.0)

  -- Рамка по краю экрана — заодно видно, что координаты совпадают
  -- с координатами тача из onTouch.
  imgui.DrawRect(2, 2, w - 2, h - 2, 0.2, 0.8, 1.0, 0.25, 2)
end

function onTouch(action, id, x, y)
  -- 0 = DOWN, 1 = UP, 2 = MOVE, 5/6 = доп. палец
  if action == 0 then
    log(('касание id=%d в (%d, %d)'):format(id, x, y))
  end
  -- Ничего не возвращаем — событие уходит игре как обычно.
end
