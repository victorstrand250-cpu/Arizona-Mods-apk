-- AGLoader: минимальный пример.
-- Положите файл в /sdcard/Android/media/<пакет>/agloader/scripts/

script_name('Hello')
script_author('agloader')
script_version('1.0')

local counter = 0
local show = true
local slider = 50

function main()
  log('привет из main(), загрузчик ' .. loaderVersion())

  local w, h = getScreenSize()
  log(('экран: %dx%d'):format(w, h))

  local base, size, path = memory.getmodulebase('libag-client.so')
  if base then
    log(('движок: 0x%X, %d КБ'):format(base, size / 1024))
    log('путь: ' .. path)
  else
    log('движок не найден: ' .. tostring(size))
  end

  while true do
    wait(5000)
    counter = counter + 1
    log('тик ' .. counter .. ', кадров всего: ' .. getFrameCount())
  end
end

function onImgui()
  if not show then return end

  imgui.SetNextWindowSize(420, 220, imgui.Cond_FirstUseEver)
  local visible, open = imgui.Begin('Hello AGLoader', show)
  show = open
  if visible then
    imgui.Text('Тиков main(): ' .. counter)
    imgui.Text(('Кадр: %.2f мс'):format(getFrameTime() * 1000))
    imgui.Separator()

    local changed, value = imgui.SliderInt('ползунок', slider, 0, 100)
    if changed then slider = value end

    if imgui.Button('в лог') then
      log('кнопка нажата, ползунок = ' .. slider)
    end
  end
  imgui.End()
end

function onScriptTerminate()
  log('скрипт остановлен')
end
