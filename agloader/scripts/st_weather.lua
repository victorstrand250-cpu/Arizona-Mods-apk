-- Weather & Time — порт скрипта Victor Strand под AGLoader.
--
-- Открыть: /stmenu
--
-- Про движок. Опкодов SCM (forceWeatherNow, setRainLevel, setTimeOfDay) в
-- новом движке нет, поэтому погода и время меняются записью в память.
-- Два способа:
--
--   1. Встроенный редактор таймцикла. У самого движка есть отладочное окно
--      «Timecycle editor», выключенное флагом в памяти. Вкладка «Движок»
--      его включает. Это родной редактор игры — вкладка работает сразу,
--      искать ничего не надо.
--
--   2. Прямая запись часа/минут/погоды. Движок собран без символов, эти
--      переменные лежат в куче внутри синглтона, и их адреса надо один раз
--      найти вкладкой «Поиск». Сохраняются они смещением внутри синглтона,
--      поэтому переживают перезапуск игры.

script_name('Weather & Time')
script_author('Victor Strand')
script_version('5.0')

-- ═════════════════════════════════════════════════════════════ константы

-- Найдено разбором libag-client.so (arm64, v17.7.1).
-- Флаг служит движку и включателем окна, и параметром p_open у ImGui::Begin.
local OFF_TC_EDITOR = 0x35E5028   -- bool: показывать «Timecycle editor»
local OFF_TC_SLOT   = 0x35E5024   -- int32: редактируемый слот, 0..7
local OFF_SINGLETON = 0x3CCA720   -- указатель на главный объект движка

local SLOT_NAMES = { '00:00', '03:00', '06:00', '09:00',
                     '12:00', '15:00', '18:00', '21:00' }

-- Размеры окна фиксированные: на телефоне окно, которое можно случайно
-- растянуть пальцем, только мешает.
local WIN_W, WIN_H = 980, 660
local LABEL_W      = 300          -- ширина колонки с подписями
local CTRL_W       = WIN_W - LABEL_W - 70
local ROW_H        = 44

local WEATHER_NAMES = {
  [0] = 'Ясно', [1] = 'Облачно', [2] = 'Облачно 2', [3] = 'Шторм',
  [4] = 'Туман', [5] = 'Гроза', [6] = 'Туман 2', [7] = 'Пасмурно',
  [8] = 'Дождь', [9] = 'Туман с дождём', [10] = 'Низкий туман',
  [11] = 'Ясно 2', [12] = 'Жарко', [13] = 'Сумерки', [14] = 'Очень ясно',
  [15] = 'Хеллоуин', [16] = 'Дождь 2', [17] = 'Туман 3', [18] = 'Облачно 3',
}
local function weatherName(id)
  return WEATHER_NAMES[id] or ('Погода ' .. id)
end

local PRESETS = {
  { 'Ясно', 0 }, { 'Облачно', 1 }, { 'Пасмурно', 7 }, { 'Дождь', 8 },
  { 'Гроза', 5 }, { 'Туман', 4 }, { 'Сумерки', 13 }, { 'Шторм', 3 },
}

-- ═══════════════════════════════════════════════════════════════ состояние

local base, singleton = 0, 0
local show = false
local tab = 1
local TABS = { 'Погода', 'Время', 'Движок', 'Поиск', 'О скрипте' }

local toast_text, toast_until = '', 0

local cfg = {
  enabled     = false,
  weather     = 0,
  hour        = 12,
  minute      = 0,
  lock_time   = true,
  -- Смещения внутри синглтона. 0 = не найдено.
  off_weather = 0, type_weather = 'u8',
  off_hour    = 0, type_hour    = 'u8',
  off_minute  = 0, type_minute  = 'u8',
}

-- ═════════════════════════════════════════════════════════════════ конфиг

local cfg_path = getPaths().config .. '/st_weather.ini'

local function saveConfig()
  local f = io.open(cfg_path, 'w')
  if not f then return end
  f:write('; Weather & Time для AGLoader\n')
  for _, k in ipairs({ 'enabled', 'weather', 'hour', 'minute', 'lock_time',
                       'off_weather', 'type_weather', 'off_hour', 'type_hour',
                       'off_minute', 'type_minute' }) do
    local v = cfg[k]
    if type(v) == 'boolean' then v = v and 'true' or 'false' end
    f:write(('%s=%s\n'):format(k, tostring(v)))
  end
  f:close()
end

local function loadConfig()
  local f = io.open(cfg_path, 'r')
  if not f then return end
  for line in f:lines() do
    local k, v = line:match('^(%w+)=(.*)$')
    if k and cfg[k] ~= nil then
      if type(cfg[k]) == 'boolean' then
        cfg[k] = (v == 'true')
      elseif type(cfg[k]) == 'number' then
        cfg[k] = tonumber(v) or cfg[k]
      else
        cfg[k] = v
      end
    end
  end
  f:close()
end

local function toast(text)
  toast_text, toast_until = text, os.clock() + 4
  log(text)
end

-- ══════════════════════════════════════════════════════ доступ к движку

-- Синглтон живёт в куче, его адрес меняется от запуска к запуску, поэтому
-- берём его заново каждый раз через указатель в .bss библиотеки.
local function refreshSingleton()
  local p = memory.deref(base + OFF_SINGLETON)
  singleton = (p and p > 0x10000) and p or 0
  return singleton
end

local function writeTyped(addr, vtype, value)
  if vtype == 'u8'  then return memory.writeu8(addr, value) end
  if vtype == 'u16' then return memory.writeu16(addr, value) end
  return memory.writei32(addr, value)
end

local function readTyped(addr, vtype)
  if vtype == 'u8'  then return memory.readu8(addr) end
  if vtype == 'u16' then return memory.readu16(addr) end
  return memory.readi32(addr)
end

local function fieldAddr(offset)
  if offset == 0 then return nil end
  if singleton == 0 and refreshSingleton() == 0 then return nil end
  return singleton + offset
end

local function applyNow()
  if not cfg.enabled then return end
  local a = fieldAddr(cfg.off_weather)
  if a then writeTyped(a, cfg.type_weather, cfg.weather) end
  if cfg.lock_time then
    a = fieldAddr(cfg.off_hour)
    if a then writeTyped(a, cfg.type_hour, cfg.hour) end
    a = fieldAddr(cfg.off_minute)
    if a then writeTyped(a, cfg.type_minute, cfg.minute) end
  end
end

-- ═══════════════════════════════════════════════ встроенный редактор

local function tcEditorEnabled()
  return (memory.readu8(base + OFF_TC_EDITOR) or 0) ~= 0
end

local function tcEditorSet(on)
  memory.writeu8(base + OFF_TC_EDITOR, on and 1 or 0)
end

local function tcSlot()
  return memory.readi32(base + OFF_TC_SLOT) or 0
end

-- ═══════════════════════════════════════════════════════ поиск адресов

local finder = {
  target  = 1,
  vtype   = 'u8',
  value   = 12,
  list    = nil,
  count   = 0,
  step    = 0,
  message = 'впишите значение, которое видите в игре сейчас, и нажмите «Начать»',
}
local TARGETS   = { 'час', 'минуты', 'погода' }
local VTYPES    = { 'u8', 'u16', 'i32' }

local function finderStart()
  -- Ищем везде, включая кучу: переменные движка лежат в синглтоне, а не
  -- в .bss библиотеки, и поиск только по модулю их не видит.
  local list, count, truncated = memory.findvalue(finder.value, finder.vtype, 'all')
  if not list then
    finder.message = 'ошибка: ' .. tostring(count)
    return
  end
  finder.list, finder.count, finder.step = list, count, 1
  finder.message = ('найдено %d. Дождитесь, пока значение в игре изменится, ' ..
                    'впишите новое и жмите «Отсеять»'):format(count)
  if truncated then
    finder.message = finder.message ..
      ' Список обрезан по лимиту — возьмите значение поредче ' ..
      '(например, не 0 и не 1) или тип пошире.'
  end
end

local function finderRefine()
  if not finder.list then
    finder.message = 'сначала «Начать»'
    return
  end
  local before = finder.count
  local list, count = memory.refine(finder.list, finder.value, finder.vtype)
  if not list then
    finder.message = 'ошибка: ' .. tostring(count)
    return
  end
  finder.list, finder.count = list, count
  finder.step = finder.step + 1

  if count == 0 then
    finder.message = 'не осталось ничего — начните заново, возможно другой тип'
  elseif count == before then
    finder.message = ('осталось %d — столько же, сколько было. Значение в игре ' ..
                      'не менялось либо вписано то же самое'):format(count)
  elseif count <= 40 then
    finder.message = ('осталось %d — выбирайте нужный ниже'):format(count)
  else
    finder.message = ('было %d, осталось %d. Повторите с новым значением')
                     :format(before, count)
  end
end

local function finderSave(addr)
  if singleton == 0 and refreshSingleton() == 0 then
    toast('синглтон движка не найден, сохранять смещение не от чего')
    return
  end
  local offset = addr - singleton
  if offset <= 0 or offset > 0x400000 then
    toast(('адрес 0x%X вне синглтона — такой не переживёт перезапуск')
          :format(addr))
    return
  end
  if finder.target == 1 then
    cfg.off_hour, cfg.type_hour = offset, finder.vtype
  elseif finder.target == 2 then
    cfg.off_minute, cfg.type_minute = offset, finder.vtype
  else
    cfg.off_weather, cfg.type_weather = offset, finder.vtype
  end
  saveConfig()
  toast(('%s: сохранено смещение +0x%X (%s)')
        :format(TARGETS[finder.target], offset, finder.vtype))
end

-- ══════════════════════════════════════════════════════════ виджеты сетки

-- Подпись слева, виджет справа, всегда на одних и тех же координатах.
local function label(text)
  imgui.AlignTextToFramePadding()
  imgui.Text(text)
  imgui.SameLine(LABEL_W)
  imgui.SetNextItemWidth(CTRL_W)
end

local function sectionTitle(text)
  imgui.Spacing()
  imgui.TextColored(text, 0.82, 0.68, 0.22, 1.0)
  imgui.Separator()
  imgui.Spacing()
end

-- ══════════════════════════════════════════════════════════════ вкладки

local function tabWeather()
  local ok = cfg.off_weather ~= 0
  if not ok then
    imgui.TextColored('Адрес погоды не найден — вкладка «Поиск».',
                      1.0, 0.5, 0.4, 1.0)
    imgui.Spacing()
  end

  sectionTitle('Быстрые пресеты')
  local per_row = 4
  local bw = (CTRL_W + LABEL_W - (per_row - 1) * 10) / per_row
  for i, p in ipairs(PRESETS) do
    if (i - 1) % per_row ~= 0 then imgui.SameLine(0, 10) end
    if imgui.Button(p[1] .. '##p' .. i, bw, ROW_H) then
      cfg.weather = p[2]
      saveConfig()
      applyNow()
    end
  end

  sectionTitle('Вручную')
  label('Погода')
  local ch, v = imgui.SliderInt('##w', cfg.weather, 0, 45)
  if ch then cfg.weather = v; saveConfig(); applyNow() end

  label('Сейчас выбрано')
  imgui.Text(('%s  [ID %d]'):format(weatherName(cfg.weather), cfg.weather))

  if ok then
    label('В памяти')
    local a = fieldAddr(cfg.off_weather)
    imgui.Text(a and tostring(readTyped(a, cfg.type_weather)) or 'нет доступа')
  end
end

local function tabTime()
  local ok = cfg.off_hour ~= 0
  if not ok then
    imgui.TextColored('Адрес времени не найден — вкладка «Поиск».',
                      1.0, 0.5, 0.4, 1.0)
    imgui.Spacing()
  end

  sectionTitle('Время суток')
  label('Час')
  local ch, v = imgui.SliderInt('##h', cfg.hour, 0, 23)
  if ch then cfg.hour = v; saveConfig(); applyNow() end

  label('Минуты')
  ch, v = imgui.SliderInt('##m', cfg.minute, 0, 59)
  if ch then cfg.minute = v; saveConfig(); applyNow() end

  label('Установлено')
  imgui.Text(('%02d:%02d'):format(cfg.hour, cfg.minute))

  sectionTitle('Поведение')
  label('Держать время')
  ch, v = imgui.Checkbox('##lock', cfg.lock_time)
  if ch then cfg.lock_time = v; saveConfig() end
  imgui.SameLine(0, 12)
  imgui.TextDisabled('перезаписывать каждый кадр')
end

local function tabEngine()
  imgui.TextWrapped(
    'У движка есть собственное отладочное окно «Timecycle editor»: ' ..
    'освещение, туман, небо и постобработка по восьми точкам суток. ' ..
    'Оно скомпилировано в игру, но выключено флагом в памяти — ' ..
    'кнопка ниже его переключает. Искать ничего не нужно, адрес известен ' ..
    'из разбора библиотеки.')

  sectionTitle('Редактор таймцикла')

  local on = tcEditorEnabled()
  label('Состояние')
  if on then
    imgui.TextColored('открыт', 0.3, 0.9, 0.4, 1.0)
  else
    imgui.TextDisabled('закрыт')
  end

  label('Переключить')
  if imgui.Button(on and 'Закрыть редактор' or 'Открыть редактор',
                  CTRL_W, ROW_H) then
    tcEditorSet(not on)
    toast(on and 'редактор таймцикла закрыт' or 'редактор таймцикла открыт')
  end

  label('Слот редактирования')
  local slot = tcSlot()
  imgui.Text(('%d — %s'):format(slot, SLOT_NAMES[slot + 1] or '?'))

  sectionTitle('Адреса')
  label('База движка')
  imgui.Text(('0x%X'):format(base))
  label('Синглтон')
  imgui.Text(singleton ~= 0 and ('0x%X'):format(singleton) or 'не получен')
  label('Флаг редактора')
  imgui.Text(('база +0x%X'):format(OFF_TC_EDITOR))
end

local function tabFinder()
  imgui.TextWrapped(
    'Схема как в Cheat Engine. Вписываете значение, которое видите в игре ' ..
    'сейчас, жмёте «Начать». Ждёте, пока оно в игре изменится, вписываете ' ..
    'новое и жмёте «Отсеять». Два-три отсева — и остаётся пара адресов. ' ..
    'Час удобнее всего ловить так: дождаться смены часа в игре.')

  sectionTitle('Параметры')
  label('Что ищем')
  local ch, v = imgui.Combo('##tg', finder.target, TARGETS)
  if ch then finder.target = v end

  local ti = 1
  for i, t in ipairs(VTYPES) do if t == finder.vtype then ti = i end end
  label('Тип значения')
  ch, v = imgui.Combo('##ty', ti, VTYPES)
  if ch then finder.vtype = VTYPES[v] end

  label('Значение сейчас')
  ch, v = imgui.InputInt('##val', finder.value)
  if ch then finder.value = v end

  sectionTitle('Поиск')
  local bw = (CTRL_W + LABEL_W - 20) / 3
  if imgui.Button('Начать', bw, ROW_H) then finderStart() end
  imgui.SameLine(0, 10)
  if imgui.Button('Отсеять', bw, ROW_H) then finderRefine() end
  imgui.SameLine(0, 10)
  if imgui.Button('Сброс', bw, ROW_H) then
    finder.list, finder.count, finder.step = nil, 0, 0
    finder.message = 'сброшено'
  end

  imgui.Spacing()
  imgui.TextColored(('Шаг %d, кандидатов: %d'):format(finder.step, finder.count),
                    0.82, 0.68, 0.22, 1.0)
  imgui.TextWrapped(finder.message)

  if finder.list and finder.count > 0 and finder.count <= 40 then
    imgui.Spacing()
    imgui.Text('Нажмите на нужный адрес, чтобы сохранить:')
    if imgui.BeginChild('##cands', 0, 200, true) then
      for i = 1, finder.count do
        local addr = finder.list[i]
        local cur = readTyped(addr, finder.vtype)
        local rel = (singleton ~= 0) and (addr - singleton) or 0
        local mark = (rel > 0 and rel <= 0x400000)
                     and ('синглтон +0x%X'):format(rel) or 'вне синглтона'
        if imgui.Button(('0x%X   значение: %s   (%s)')
                        :format(addr, tostring(cur), mark), -1, 36) then
          finderSave(addr)
        end
      end
    end
    imgui.EndChild()
  end
end

local function tabAbout()
  sectionTitle('Скрипт')
  label('Название')   imgui.Text('Weather & Time 5.0')
  label('Автор')      imgui.Text('Victor Strand')
  label('Порт')       imgui.Text('AGLoader ' .. loaderVersion())

  sectionTitle('Команды')
  label('/stmenu')    imgui.Text('открыть это окно')
  label('/stw <id>')  imgui.Text('поставить погоду по номеру')
  label('/sttime <ч> [м]') imgui.Text('поставить время')
  label('/tcedit')    imgui.Text('редактор таймцикла движка')

  sectionTitle('Состояние')
  label('Погода')  imgui.Text(cfg.off_weather ~= 0
    and ('+0x%X (%s)'):format(cfg.off_weather, cfg.type_weather) or 'не найдена')
  label('Час')     imgui.Text(cfg.off_hour ~= 0
    and ('+0x%X (%s)'):format(cfg.off_hour, cfg.type_hour) or 'не найден')
  label('Минуты')  imgui.Text(cfg.off_minute ~= 0
    and ('+0x%X (%s)'):format(cfg.off_minute, cfg.type_minute) or 'не найдены')
end

-- ══════════════════════════════════════════════════════════════ интерфейс

function onImgui()
  if not show then return end

  local sw, sh = getScreenSize()
  imgui.SetNextWindowPos((sw - WIN_W) / 2, (sh - WIN_H) / 2,
                         imgui.Cond_FirstUseEver)
  imgui.SetNextWindowSize(WIN_W, WIN_H, imgui.Cond_Always)

  local visible, open = imgui.Begin('Weather & Time', show,
    imgui.WindowFlags_NoResize + imgui.WindowFlags_NoCollapse)
  show = open

  if visible then
    -- Шапка: выключатель и общий статус, всегда на одном месте.
    local ch, v = imgui.Checkbox('Включено', cfg.enabled)
    if ch then cfg.enabled = v; saveConfig() end
    imgui.SameLine(LABEL_W)
    if cfg.enabled then
      imgui.TextColored('применяется каждый кадр', 0.3, 0.9, 0.4, 1.0)
    else
      imgui.TextDisabled('выключено — в игру ничего не пишется')
    end

    imgui.Separator()

    -- Вкладки своими кнопками: так они одинаковой ширины и не прыгают.
    local tw = (WIN_W - 40 - (#TABS - 1) * 8) / #TABS
    for i, name in ipairs(TABS) do
      if i > 1 then imgui.SameLine(0, 8) end
      if i == tab then
        imgui.PushStyleColor(imgui.Col_Button, 0.82, 0.68, 0.22, 1.0)
        imgui.PushStyleColor(imgui.Col_Text, 0.1, 0.1, 0.1, 1.0)
      end
      if imgui.Button(name .. '##tab' .. i, tw, ROW_H) then tab = i end
      if i == tab then imgui.PopStyleColor(2) end
    end

    imgui.Separator()

    -- Содержимое в области фиксированной высоты, чтобы подвал не ездил.
    if imgui.BeginChild('##body', 0, WIN_H - 220, false) then
      if     tab == 1 then tabWeather()
      elseif tab == 2 then tabTime()
      elseif tab == 3 then tabEngine()
      elseif tab == 4 then tabFinder()
      else                 tabAbout()
      end
    end
    imgui.EndChild()

    imgui.Separator()
    if os.clock() < toast_until then
      imgui.TextColored(toast_text, 0.3, 0.9, 0.4, 1.0)
    else
      imgui.TextDisabled('Weather & Time 5.0  |  /stmenu  |  Victor Strand')
    end
  end
  imgui.End()
end

-- ══════════════════════════════════════════════════════════════════ main

function main()
  base = memory.getclientbase()
  if not base or base == 0 then
    log('база движка не получена, скрипт бесполезен')
    return
  end
  refreshSingleton()
  loadConfig()

  log(('база движка 0x%X, синглтон 0x%X'):format(base, singleton))

  registerChatCommand('stmenu', function() show = not show end)

  registerChatCommand('stw', function(args)
    local id = tonumber(args)
    if not id then toast('нужно: /stw <номер погоды 0..45>'); return end
    cfg.weather = math.max(0, math.min(45, math.floor(id)))
    saveConfig()
    applyNow()
    toast(('погода: %s [%d]'):format(weatherName(cfg.weather), cfg.weather))
  end)

  registerChatCommand('sttime', function(args)
    local h, m = args:match('^(%d+)%s*(%d*)$')
    if not h then toast('нужно: /sttime <час> [минуты]'); return end
    cfg.hour = math.max(0, math.min(23, tonumber(h)))
    cfg.minute = math.max(0, math.min(59, tonumber(m) or 0))
    saveConfig()
    applyNow()
    toast(('время: %02d:%02d'):format(cfg.hour, cfg.minute))
  end)

  registerChatCommand('tcedit', function()
    local on = tcEditorEnabled()
    tcEditorSet(not on)
    toast(on and 'редактор таймцикла закрыт' or 'редактор таймцикла открыт')
  end)

  log('команды: /stmenu, /stw, /sttime, /tcedit')

  while true do
    wait(0)
    if cfg.enabled then
      applyNow()
    end
  end
end

function onScriptTerminate()
  saveConfig()
end
