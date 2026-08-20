-- AGLoader — проверочный скрипт.
--
-- Кладётся в /sdcard/Android/media/com.arizonagames.arizona.web/agloader/scripts/
-- Проверяет по очереди всё, что умеет загрузчик: корутину main, события,
-- ImGui-окно, рисование поверх игры, тач и работу с памятью движка.
--
-- Открыть окно: кнопка «Тест» рядом с кнопкой AGLoader.

script_name('AGLoader Test')
script_author('agloader')
script_version('1.0')

-- ------------------------------------------------------------------ состояние

local show = true
local ticks = 0
local started_at = os.time()

local overlay = true
local eat_touch = false
local box_size = 120

local last_touch = 'касаний ещё не было'
local touch_count = 0

local client_base, client_size = 0, 0
local scan_pattern = 'FD 7B BF A9'      -- stp x29, x30, [sp, #-16]! — пролог функции arm64
local scan_result = 'нажмите «Искать»'
local scan_addr = 0

local watch_addr = ''
local watch_text = ''

local fps, fps_acc, fps_frames = 0, 0, 0

-- --------------------------------------------------------------------- main()

function main()
  log('=== проверка AGLoader ' .. loaderVersion() .. ' ===')

  local w, h = getScreenSize()
  log(('экран: %dx%d'):format(w, h))

  local p = getPaths()
  log('пакет:   ' .. p.package)
  log('скрипты: ' .. p.scripts)
  log('lib:     ' .. p.lib)

  client_base, client_size = memory.getclientbase()
  if client_base and client_base > 0 then
    log(('движок: 0x%X, %d КБ'):format(client_base, client_size / 1024))
  else
    log('движок ещё не резолвнут — это странно, смотрите agloader.log')
  end

  local mods = memory.getmodules()
  local so = 0
  for _, m in ipairs(mods) do
    if m.name:sub(-3) == '.so' then so = so + 1 end
  end
  log(('модулей в процессе: %d, из них .so: %d'):format(#mods, so))

  -- Проверяем, что чтение памяти живое: первые 4 байта модуля — сигнатура ELF.
  local magic = memory.read(client_base, 4)
  if magic == '\127ELF' then
    log('memory.read работает: по базе движка лежит ELF-заголовок')
  else
    log('memory.read вернул не ELF — проверьте лог')
  end

  -- Проверяем, что неверный адрес не роняет игру, а возвращает ошибку.
  local bad, err = memory.read(0x10, 4)
  if bad == nil then
    log('чтение битого адреса безопасно отклонено: ' .. tostring(err))
  else
    log('внимание: чтение по 0x10 почему-то удалось')
  end

  log('=== проверка пройдена, окно открыто ===')

  while true do
    wait(10000)
    ticks = ticks + 1
    log(('живу %d с, кадров: %d'):format(os.time() - started_at, getFrameCount()))
  end
end

-- ------------------------------------------------------------------- события

function onFrame(dt)
  fps_acc = fps_acc + dt
  fps_frames = fps_frames + 1
  if fps_acc >= 0.5 then
    fps = fps_frames / fps_acc
    fps_acc, fps_frames = 0, 0
  end
end

function onTouch(action, id, x, y)
  local names = { [0] = 'DOWN', [1] = 'UP', [2] = 'MOVE', [3] = 'CANCEL',
                  [5] = 'POINTER_DOWN', [6] = 'POINTER_UP' }
  last_touch = ('%s  палец %d  (%d, %d)'):format(names[action] or action, id, x, y)

  if action == 0 then
    touch_count = touch_count + 1
    if eat_touch then
      -- false = событие поглощено, игра его не увидит
      return false
    end
  end
end

function onPause() log('игра свёрнута') end
function onResume() log('игра развёрнута') end
function onScriptTerminate() log('скрипт остановлен') end

-- ------------------------------------------------------------------ действия

local function do_scan()
  local addr, offset = memory.scan(scan_pattern, 'libag-client.so', 1)
  if not addr then
    scan_result = 'не найдено: ' .. tostring(offset)
    scan_addr = 0
    return
  end
  scan_addr = addr
  scan_result = ('0x%X  (смещение +0x%X)'):format(addr, offset)
  watch_addr = ('0x%X'):format(addr)
  log('scan: ' .. scan_result)
end

local function do_watch()
  local addr = tonumber(watch_addr)
  if not addr then
    watch_text = 'адрес не разобран'
    return
  end
  local hex, err = memory.hex(addr, 32)
  if not hex then
    watch_text = 'ошибка чтения: ' .. tostring(err)
    return
  end
  local u32 = memory.readu32(addr)
  watch_text = hex .. '\n\nкак uint32: ' .. tostring(u32)
end

-- ----------------------------------------------------------------- интерфейс

function onImgui()
  -- 1. Рисование поверх игры — окно для этого не нужно.
  if overlay then
    local w, h = getScreenSize()
    local line = ('AGLoader %s | %.0f FPS | касаний: %d'):format(
      loaderVersion(), fps, touch_count)
    local tw, th = imgui.CalcTextSize(line)
    local x, y = w - tw - 30, 20

    imgui.DrawRectFilled(x - 10, y - 6, x + tw + 10, y + th + 6, 0, 0, 0, 0.6)
    imgui.DrawText(x, y, line, 0.4, 1.0, 0.6, 1.0)

    -- Квадрат по центру — видно, что координаты совпадают с тачем.
    local cx, cy = w / 2, h / 2
    local s = box_size
    imgui.DrawRect(cx - s, cy - s, cx + s, cy + s, 0.2, 0.8, 1.0, 0.5, 3)
  end

  -- 2. Кнопка вызова окна.
  if not show then
    imgui.SetNextWindowPos(220, 24, imgui.Cond_FirstUseEver)
    imgui.SetNextWindowSize(130, 60, imgui.Cond_Always)
    local btn_visible = imgui.Begin('##test_btn', nil,
      imgui.WindowFlags_NoTitleBar + imgui.WindowFlags_NoResize +
      imgui.WindowFlags_NoScrollbar)
    if btn_visible and imgui.Button('Тест', -1, -1) then
      show = true
    end
    imgui.End()  -- End вызывается всегда, даже если Begin вернул false
    return
  end

  -- 3. Основное окно.
  imgui.SetNextWindowSize(680, 520, imgui.Cond_FirstUseEver)
  local visible, open = imgui.Begin('Проверка AGLoader', show)
  show = open

  if visible then
    imgui.Text(('FPS %.0f   кадр %.2f мс   тиков main: %d'):format(
      fps, getFrameTime() * 1000, ticks))
    imgui.Separator()

    if imgui.BeginTabBar('##t') then

      if imgui.BeginTabItem('Общее') then
        local w, h = getScreenSize()
        imgui.Text(('экран: %dx%d'):format(w, h))
        imgui.Text(('кадров всего: %d'):format(getFrameCount()))
        imgui.Text(('движок: 0x%X (%d КБ)'):format(client_base, client_size / 1024))
        imgui.Separator()

        local ch
        ch, overlay = imgui.Checkbox('рисовать поверх игры', overlay)
        ch, box_size = imgui.SliderInt('размер рамки', box_size, 40, 400)

        imgui.Separator()
        if imgui.Button('написать в лог') then
          log('кнопка нажата, рамка = ' .. box_size)
        end
        imgui.SameLine()
        if imgui.Button('перезагрузить скрипты') then
          reloadScripts()
        end
        imgui.EndTabItem()
      end

      if imgui.BeginTabItem('Тач') then
        imgui.Text('последнее касание:')
        imgui.TextColored(last_touch, 0.5, 0.9, 1.0, 1.0)
        imgui.Text(('нажатий всего: %d'):format(touch_count))
        imgui.Separator()

        local ch
        ch, eat_touch = imgui.Checkbox('поглощать касания (игра их не увидит)', eat_touch)
        imgui.TextWrapped(
          'Включите и потыкайте по игре: персонаж не должен реагировать. ' ..
          'Само меню при этом работает — оно поглощает касания отдельно.')
        imgui.EndTabItem()
      end

      if imgui.BeginTabItem('Память') then
        local ch, v = imgui.InputText('сигнатура', scan_pattern, 128)
        if ch then scan_pattern = v end

        if imgui.Button('Искать') then do_scan() end
        imgui.SameLine()
        imgui.Text(scan_result)

        imgui.TextWrapped(
          'По умолчанию ищется FD 7B BF A9 — пролог функции arm64. ' ..
          'Он есть в любом движке, так что находка подтверждает, что сканер жив. ' ..
          '?? означает любой байт. Поиск по 10 МБ занимает доли секунды, ' ..
          'но кадр на это время подвиснет.')

        imgui.Separator()
        ch, v = imgui.InputText('адрес', watch_addr, 32)
        if ch then watch_addr = v end
        if imgui.Button('Прочитать 32 байта') then do_watch() end
        if watch_text ~= '' then
          imgui.Separator()
          imgui.Text(watch_text)
        end
        imgui.EndTabItem()
      end

      if imgui.BeginTabItem('Модули') then
        for _, m in ipairs(memory.getmodules()) do
          if m.name:sub(-3) == '.so' then
            imgui.Text(('%-30s 0x%X  %d КБ'):format(m.name, m.base, m.size / 1024))
          end
        end
        imgui.EndTabItem()
      end

      imgui.EndTabBar()
    end
  end
  imgui.End()
end
