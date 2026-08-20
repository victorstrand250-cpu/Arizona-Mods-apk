-- Weather & Time Changer — порт под AGLoader (новый движок Arizona).
-- Оригинал: Victor Strand, v4.0 (MonetLoader).
--
-- ЧТО ИЗМЕНИЛОСЬ И ПОЧЕМУ
-- -----------------------
-- Оригинал держался на опкодах SCM: forceWeatherNow, setRainLevel,
-- setTimeOfDay. В новом движке виртуальной машины SCM нет вообще, как нет
-- ни SA-MP, ни RakNet, поэтому ни один из этих вызовов сюда не переносится.
--
-- Единственный доступный путь — писать значения прямо в память движка.
-- Но движок собран stripped: адреса погоды и времени неизвестны и меняются
-- от сборки к сборке. Поэтому здесь есть вкладка «Поиск», которая находит
-- их так же, как это делает Cheat Engine: ищем текущее значение, ждём, пока
-- оно изменится в игре, отсеиваем лишнее — и так пока не останется один-два
-- адреса. Найденное сохраняется в конфиг и дальше применяется само.
--
-- Смещение (offset) стабильно между запусками, сам адрес — нет: база
-- libag-client.so каждый раз новая из-за ASLR. Скрипт хранит именно
-- смещение и складывает его с базой при старте.
--
-- Открыть меню: /stmenu

script_name('Weather & Time Changer')
script_author('Victor Strand (порт под AGLoader)')
script_version('4.0-ag')

-- ═══════════════════════════════════════════════════════ конфиг

local paths = getPaths()
local CONFIG = paths.config .. '/st_weather.ini'

local cfg = {
  enabled     = false,
  weather     = 0,
  hour        = 12,
  minute      = 0,
  lock_time   = true,
  -- смещения от базы движка; 0 = не найдено
  off_weather = 0,
  off_hour    = 0,
  off_minute  = 0,
  type_weather = 'u8',
  type_hour    = 'u8',
  type_minute  = 'u8',
}

local function loadConfig()
  local f = io.open(CONFIG, 'r')
  if not f then return end
  for line in f:lines() do
    local k, v = line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
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

local function saveConfig()
  local f = io.open(CONFIG, 'w')
  if not f then
    log('не смог записать конфиг: ' .. CONFIG)
    return
  end
  f:write('# Weather & Time Changer для AGLoader\n')
  local keys = {}
  for k in pairs(cfg) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    f:write(k .. ' = ' .. tostring(cfg[k]) .. '\n')
  end
  f:close()
end

-- ═══════════════════════════════════════════════════════ состояние

local show      = false
local base      = 0
local status    = 'адреса не найдены — вкладка «Поиск»'
local notify    = { text = '', until_frame = 0 }

local function toast(text)
  notify.text = text
  notify.until_frame = getFrameCount() + 240   -- ~4 секунды при 60 FPS
  log(text)
end

-- ═══════════════════════════════════════════════════════ погоды

local weatherNames = {
  [0]='Ясно', [1]='Облачно', [2]='Облачно 2', [3]='Шторм', [4]='Туман',
  [5]='Гроза', [6]='Туман 2', [7]='Пасмурно', [8]='Дождь', [9]='Туман и дождь',
  [10]='Низкий туман', [11]='Ясно 2', [12]='Жарко', [13]='Сумерки',
  [14]='Очень ясно', [15]='Хэллоуин', [16]='Дождь 2', [17]='Туман 3',
  [18]='Облачно 3',
}
local function wName(id) return weatherNames[id] or ('Погода ' .. id) end

local presets = {
  { label = 'Ясно',     id = 0  },
  { label = 'Облачно',  id = 1  },
  { label = 'Пасмурно', id = 7  },
  { label = 'Дождь',    id = 8  },
  { label = 'Гроза',    id = 5  },
  { label = 'Туман',    id = 4  },
  { label = 'Сумерки',  id = 13 },
  { label = 'Шторм',    id = 3  },
}

-- ═══════════════════════════════════════════════════════ применение

local function addrOf(offset)
  if base == 0 or offset == 0 then return nil end
  return base + offset
end

local function writeValue(offset, vtype, value)
  local a = addrOf(offset)
  if not a then return false end
  if vtype == 'u8' or vtype == 'i8' then
    return memory.writeu8(a, value, true)
  elseif vtype == 'u16' or vtype == 'i16' then
    return memory.writeu16(a, value, true)
  else
    return memory.writei32(a, value, true)
  end
end

local function readValue(offset, vtype)
  local a = addrOf(offset)
  if not a then return nil end
  if vtype == 'u8' or vtype == 'i8' then
    return memory.readu8(a)
  elseif vtype == 'u16' or vtype == 'i16' then
    return memory.readu16(a)
  else
    return memory.readi32(a)
  end
end

local function applyAll()
  if not cfg.enabled then return end
  if cfg.off_weather ~= 0 then
    writeValue(cfg.off_weather, cfg.type_weather, cfg.weather)
  end
  if cfg.lock_time then
    if cfg.off_hour ~= 0 then
      writeValue(cfg.off_hour, cfg.type_hour, cfg.hour)
    end
    if cfg.off_minute ~= 0 then
      writeValue(cfg.off_minute, cfg.type_minute, cfg.minute)
    end
  end
end

local function refreshStatus()
  local have = 0
  if cfg.off_weather ~= 0 then have = have + 1 end
  if cfg.off_hour    ~= 0 then have = have + 1 end
  if cfg.off_minute  ~= 0 then have = have + 1 end
  if have == 0 then
    status = 'адреса не найдены — вкладка «Поиск»'
  elseif have < 3 then
    status = ('найдено адресов: %d из 3'):format(have)
  else
    status = 'все адреса найдены'
  end
end

-- ═══════════════════════════════════════════════════════ поиск адресов

local finder = {
  target  = 1,          -- 1 = время (час), 2 = минуты, 3 = погода
  vtype   = 'u8',
  value   = 12,
  list    = nil,
  count   = 0,
  step    = 0,
  message = 'введите значение, которое сейчас в игре, и нажмите «Начать»',
}

local targetNames = { 'час', 'минуты', 'погода' }
local typeNames   = { 'u8', 'u16', 'i32' }

local function finderStart()
  local list, count = memory.findvalue(finder.value, finder.vtype)
  if not list then
    finder.message = 'ошибка: ' .. tostring(count)
    return
  end
  finder.list, finder.count, finder.step = list, count, 1
  finder.message = ('найдено %d совпадений. Дождитесь, пока значение в игре ' ..
                    'изменится, впишите новое и нажмите «Отсеять»'):format(count)
end

local function finderRefine()
  if not finder.list then
    finder.message = 'сначала «Начать»'
    return
  end
  local list, count = memory.refine(finder.list, finder.value, finder.vtype)
  if not list then
    finder.message = 'ошибка: ' .. tostring(count)
    return
  end
  finder.list, finder.count = list, count
  finder.step = finder.step + 1
  if count == 0 then
    finder.message = 'ничего не осталось — начните заново, возможно другой тип'
  elseif count <= 8 then
    finder.message = ('осталось %d — можно сохранять'):format(count)
  else
    finder.message = ('осталось %d, повторите отсев с новым значением'):format(count)
  end
end

local function finderSave(addr)
  local offset = addr - base
  if finder.target == 1 then
    cfg.off_hour, cfg.type_hour = offset, finder.vtype
  elseif finder.target == 2 then
    cfg.off_minute, cfg.type_minute = offset, finder.vtype
  else
    cfg.off_weather, cfg.type_weather = offset, finder.vtype
  end
  saveConfig()
  refreshStatus()
  toast(('%s: сохранено смещение +0x%X (%s)'):format(
    targetNames[finder.target], offset, finder.vtype))
end

-- ═══════════════════════════════════════════════════════ main

function main()
  loadConfig()
  base = memory.getclientbase()
  refreshStatus()

  registerChatCommand('stmenu', function()
    show = not show
  end)

  registerChatCommand('stw', function(args)
    local id = tonumber(args)
    if not id then
      toast('использование: /stw <id погоды 0-18>')
      return
    end
    cfg.weather = id
    cfg.enabled = true
    saveConfig()
    toast('погода: ' .. wName(id))
  end)

  registerChatCommand('sttime', function(args)
    local h, m = args:match('^(%d+)%s*:?%s*(%d*)')
    h = tonumber(h)
    if not h then
      toast('использование: /sttime <часы> [минуты]')
      return
    end
    cfg.hour = math.max(0, math.min(23, h))
    cfg.minute = math.max(0, math.min(59, tonumber(m) or 0))
    cfg.enabled = true
    cfg.lock_time = true
    saveConfig()
    toast(('время: %02d:%02d'):format(cfg.hour, cfg.minute))
  end)

  log('Weather & Time v4.0-ag загружен. Команды: /stmenu, /stw, /sttime')
  log('база движка: 0x' .. ('%X'):format(base))
  log(status)

  while true do
    wait(0)
    applyAll()
  end
end

function onScriptTerminate()
  saveConfig()
end

-- ═══════════════════════════════════════════════════════ интерфейс

local AC = { 0.82, 0.68, 0.22 }

local function accentText(s)
  imgui.TextColored(s, AC[1], AC[2], AC[3], 1.0)
end

local function tabGeneral()
  if cfg.enabled then
    imgui.PushStyleColor(imgui.Col_Button, 0.55, 0.06, 0.06, 0.9)
    if imgui.Button('[ ВЫКЛЮЧИТЬ ]', -1, 46) then
      cfg.enabled = false
      saveConfig()
      toast('выключено')
    end
    imgui.PopStyleColor(1)
  else
    imgui.PushStyleColor(imgui.Col_Button, 0.06, 0.46, 0.10, 0.9)
    if imgui.Button('[ ВКЛЮЧИТЬ ]', -1, 46) then
      cfg.enabled = true
      saveConfig()
      toast('включено')
    end
    imgui.PopStyleColor(1)
  end

  imgui.Separator()
  accentText('Быстрые пресеты:')

  for i, p in ipairs(presets) do
    if (i - 1) % 4 ~= 0 then imgui.SameLine() end
    local active = (cfg.weather == p.id)
    if active then
      imgui.PushStyleColor(imgui.Col_Button, AC[1] * 0.5, AC[2] * 0.5, AC[3] * 0.5, 1.0)
    else
      imgui.PushStyleColor(imgui.Col_Button, 1, 1, 1, 0.05)
    end
    if imgui.Button(p.label, 120, 36) then
      cfg.weather = p.id
      saveConfig()
    end
    imgui.PopStyleColor(1)
  end

  imgui.Separator()
  accentText(('Погода: %s  [ID %d]'):format(wName(cfg.weather), cfg.weather))
  imgui.PushItemWidth(-1)
  local ch, v = imgui.SliderInt('##weather', cfg.weather, 0, 18)
  if ch then cfg.weather = v; saveConfig() end

  imgui.Separator()
  accentText(('Время: %02d:%02d'):format(cfg.hour, cfg.minute))
  ch, v = imgui.SliderInt('##hour', cfg.hour, 0, 23)
  if ch then cfg.hour = v; saveConfig() end
  ch, v = imgui.SliderInt('##min', cfg.minute, 0, 59)
  if ch then cfg.minute = v; saveConfig() end
  imgui.PopItemWidth()

  ch, v = imgui.Checkbox('Заморозить время (писать каждый кадр)', cfg.lock_time)
  if ch then cfg.lock_time = v; saveConfig() end

  imgui.Separator()
  imgui.TextDisabled('Команды: /stmenu, /stw <id>, /sttime <ч> [м]')
end

local function tabFinder()
  imgui.TextWrapped(
    'Движок собран без символов, поэтому адреса погоды и времени надо найти ' ..
    'один раз вручную. Схема как в Cheat Engine: вписываете значение, ' ..
    'которое видите в игре сейчас, жмёте «Начать». Ждёте, пока оно ' ..
    'изменится, вписываете новое, жмёте «Отсеять» — и так, пока не ' ..
    'останется пара адресов.')
  imgui.Separator()

  local ch, v = imgui.Combo('что ищем', finder.target, targetNames)
  if ch then finder.target = v end

  local ti = 1
  for i, t in ipairs(typeNames) do
    if t == finder.vtype then ti = i end
  end
  ch, v = imgui.Combo('тип значения', ti, typeNames)
  if ch then finder.vtype = typeNames[v] end

  ch, v = imgui.InputInt('текущее значение', finder.value)
  if ch then finder.value = v end

  if imgui.Button('Начать', 160, 40) then finderStart() end
  imgui.SameLine()
  if imgui.Button('Отсеять', 160, 40) then finderRefine() end
  imgui.SameLine()
  if imgui.Button('Сброс', 160, 40) then
    finder.list, finder.count, finder.step = nil, 0, 0
    finder.message = 'сброшено'
  end

  imgui.Separator()
  accentText(('шаг %d, кандидатов: %d'):format(finder.step, finder.count))
  imgui.TextWrapped(finder.message)

  if finder.list and finder.count > 0 and finder.count <= 30 then
    imgui.Separator()
    imgui.Text('Кандидаты (нажмите, чтобы сохранить):')
    if imgui.BeginChild('##cands', 0, 220, true) then
      for i = 1, finder.count do
        local addr = finder.list[i]
        local cur = memory.readu8(addr)
        if imgui.Button(('+0x%X   сейчас: %s'):format(addr - base, tostring(cur)),
                        -1, 34) then
          finderSave(addr)
        end
      end
    end
    imgui.EndChild()
  end
end

local function tabStatus()
  imgui.Text(('база движка: 0x%X'):format(base))
  imgui.Separator()

  local rows = {
    { 'час',     cfg.off_hour,    cfg.type_hour },
    { 'минуты',  cfg.off_minute,  cfg.type_minute },
    { 'погода',  cfg.off_weather, cfg.type_weather },
  }
  for _, r in ipairs(rows) do
    if r[2] == 0 then
      imgui.TextColored(('%-8s не найден'):format(r[1]), 1.0, 0.45, 0.45, 1.0)
    else
      local cur = readValue(r[2], r[3])
      imgui.TextColored(
        ('%-8s +0x%X (%s), сейчас: %s'):format(r[1], r[2], r[3], tostring(cur)),
        0.4, 0.9, 0.4, 1.0)
    end
  end

  imgui.Separator()
  if imgui.Button('Забыть все адреса', -1, 38) then
    cfg.off_hour, cfg.off_minute, cfg.off_weather = 0, 0, 0
    saveConfig()
    refreshStatus()
    toast('адреса сброшены')
  end

  imgui.Separator()
  imgui.TextDisabled('конфиг: ' .. CONFIG)
  imgui.TextDisabled('автор оригинала: Victor Strand')
end

function onImgui()
  -- Всплывающее уведомление вместо sampAddChatMessage: чат нам не пишет.
  if notify.text ~= '' and getFrameCount() < notify.until_frame then
    local w = getScreenSize()
    local tw, th = imgui.CalcTextSize(notify.text)
    local x, y = (w - tw) * 0.5, 90
    imgui.DrawRectFilled(x - 16, y - 8, x + tw + 16, y + th + 8, 0, 0, 0, 0.65)
    imgui.DrawText(x, y, notify.text, AC[1], AC[2], AC[3], 1.0)
  end

  if not show then return end

  imgui.SetNextWindowSize(620, 560, imgui.Cond_FirstUseEver)
  local visible, open = imgui.Begin('Weather & Time Changer', show)
  show = open

  if visible then
    if cfg.enabled then
      imgui.TextColored('активно', 0.18, 0.88, 0.32, 1.0)
    else
      imgui.TextColored('выключено', 0.6, 0.6, 0.6, 1.0)
    end
    imgui.SameLine()
    imgui.TextDisabled('| ' .. status)
    imgui.Separator()

    if imgui.BeginTabBar('##stw') then
      if imgui.BeginTabItem('Настройки') then tabGeneral(); imgui.EndTabItem() end
      if imgui.BeginTabItem('Поиск')      then tabFinder();  imgui.EndTabItem() end
      if imgui.BeginTabItem('Адреса')     then tabStatus();  imgui.EndTabItem() end
      imgui.EndTabBar()
    end
  end
  imgui.End()
end
