-- Разведка движка — поиск камеры, игрока и настройка проекции.
--
-- Открыть: /recon
--
-- Зачем. Движок собран без символов, поэтому адреса камеры и игрока в нём
-- не написаны нигде — их надо найти на живой игре. Ищутся они не перебором
-- значений, а по форме данных: матрица положения узнаётся математически,
-- у неё верхний левый блок 3x3 ортонормирован (оси единичной длины и
-- взаимно перпендикулярны). Так выглядят матрицы камеры, игрока,
-- транспорта и объектов.
--
-- Дальше кандидаты разделяются поведением:
--   * покрутили камеру, не сходя с места — сдвинулась только камера;
--   * прошли пару шагов — сдвинулся игрок.
--
-- Найдя камеру, можно считать перевод мировых координат в экранные, а это
-- то, без чего не работает ни один ESP.

script_name('Разведка движка')
script_author('agloader')
script_version('1.0')

local MDS, sw, sh = 1, 1280, 720

local function refreshMetrics()
  local s = getUiScale()
  if s and s > 0 then MDS = s end
  local w, h = getScreenSize()
  if w and w > 0 then sw, sh = w, h end
end

-- ═══════════════════════════════════════════════════════════════ состояние

local show = false
local step = 0            -- 0 не начинали, 1 снят слепок, 2 отсеяли камеру, 3 нашли игрока
local status = 'нажмите «Сканировать»'
local busy = ''

local cands   = {}        -- адреса-кандидаты
local snap    = {}        -- addr -> матрица на момент слепка
local moving  = {}        -- те, что сдвинулись при повороте камеры
local staying = {}        -- те, что не сдвинулись

local camAddr, playerAddr = 0, 0

-- Настройка проекции.
local fov       = 70
local fwdAxis   = 2       -- 1 right, 2 up, 3 at
local upAxis    = 3
local fwdSign   = 1
local mirrorX   = false
local mirrorY   = false
local showDots  = true
local dotLimit  = 400

local cfgPath = getPaths().config .. '/recon.ini'

-- ═════════════════════════════════════════════════════════════ работа с матрицей

-- Матрица лежит как 16 float подряд: три оси по четыре числа и сдвиг.
-- В Lua индексы с единицы, поэтому строка i начинается с (i-1)*4+1.
local function row(m, i)
  local o = (i - 1) * 4
  return m[o + 1], m[o + 2], m[o + 3]
end

local function pos(m)
  return m[13], m[14], m[15]
end

local function dot3(ax, ay, az, bx, by, bz)
  return ax * bx + ay * by + az * bz
end

local function dist3(a, b)
  local dx, dy, dz = a[13] - b[13], a[14] - b[14], a[15] - b[15]
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Насколько повернулась матрица: сумма расхождений по первой оси.
local function rotDelta(a, b)
  local d = 0
  for i = 1, 3 do
    d = d + math.abs(a[i] - b[i])
  end
  return d
end

-- ══════════════════════════════════════════════════════════ проекция

local function worldToScreen(wx, wy, wz, cam)
  local px, py, pz = pos(cam)
  local dx, dy, dz = wx - px, wy - py, wz - pz

  local fx, fy, fz = row(cam, fwdAxis)
  fx, fy, fz = fx * fwdSign, fy * fwdSign, fz * fwdSign
  local ux, uy, uz = row(cam, upAxis)

  -- Правая ось — векторное произведение, так она всегда согласована
  -- с выбранными «вперёд» и «вверх».
  local rx = fy * uz - fz * uy
  local ry = fz * ux - fx * uz
  local rz = fx * uy - fy * ux

  local depth = dot3(dx, dy, dz, fx, fy, fz)
  if depth <= 0.05 then return nil end

  local hx = dot3(dx, dy, dz, rx, ry, rz)
  local hy = dot3(dx, dy, dz, ux, uy, uz)

  local tanHalf = math.tan(math.rad(fov) / 2)
  local aspect  = sw / sh

  local nx = hx / (depth * tanHalf * aspect)
  local ny = hy / (depth * tanHalf)
  if mirrorX then nx = -nx end
  if mirrorY then ny = -ny end

  return sw / 2 + nx * (sw / 2), sh / 2 - ny * (sh / 2), depth
end

-- ═══════════════════════════════════════════════════════════════ шаги

local function takeSnapshot(list)
  local out = {}
  for _, a in ipairs(list) do
    local m = memory.readmatrix(a)
    if m then out[a] = m end
  end
  return out
end

local function doScan()
  busy = 'сканирую память…'
  local list, count, truncated = memory.findmatrix({ tol = 0.01, limit = 20000 })
  busy = ''
  if not list then
    status = 'ошибка: ' .. tostring(count)
    return
  end
  cands = list
  snap = takeSnapshot(cands)
  step = 1
  status = ('найдено матриц: %d%s. Теперь встаньте на месте, покрутите ' ..
            'камеру и нажмите «Камера сдвинулась»')
           :format(count, truncated and ' (список обрезан)' or '')
  log(('[разведка] матриц-кандидатов: %d'):format(count))
end

local function splitByMovement(threshold)
  local moved, stayed = {}, {}
  for _, a in ipairs(cands) do
    local before = snap[a]
    local now = memory.readmatrix(a)
    if before and now then
      if dist3(before, now) > threshold or rotDelta(before, now) > 0.05 then
        moved[#moved + 1] = a
      else
        stayed[#stayed + 1] = a
      end
    end
  end
  return moved, stayed
end

local function doCameraStep()
  moving, staying = splitByMovement(0.3)
  if #moving == 0 then
    status = 'ничего не сдвинулось — покрутите камеру подольше и повторите'
    return
  end
  -- Кандидат в камеру: сдвинулся сильнее всех по положению.
  local best, bestD = 0, -1
  for _, a in ipairs(moving) do
    local before, now = snap[a], memory.readmatrix(a)
    if before and now then
      local d = dist3(before, now)
      if d > bestD then best, bestD = a, d end
    end
  end
  camAddr = best
  snap = takeSnapshot(staying)
  step = 2
  status = ('камера: 0x%X (сдвиг %.1f). Осталось неподвижных: %d. ' ..
            'Теперь пройдите несколько шагов и нажмите «Я прошёл»')
           :format(camAddr, bestD, #staying)
  log(('[разведка] камера 0x%X'):format(camAddr))
end

local function doPlayerStep()
  local moved = {}
  for _, a in ipairs(staying) do
    local before, now = snap[a], memory.readmatrix(a)
    if before and now and dist3(before, now) > 0.5 then
      moved[#moved + 1] = { addr = a, d = dist3(before, now) }
    end
  end
  if #moved == 0 then
    status = 'ничего не сдвинулось — пройдите подальше и повторите'
    return
  end
  table.sort(moved, function(x, y) return x.d > y.d end)
  playerAddr = moved[1].addr
  step = 3
  status = ('игрок: 0x%X (сдвиг %.1f). Кандидатов было %d. ' ..
            'Переходите к настройке проекции')
           :format(playerAddr, moved[1].d, #moved)
  log(('[разведка] игрок 0x%X'):format(playerAddr))
end

local function saveFound()
  local f = io.open(cfgPath, 'w')
  if not f then return end
  f:write('; найденное разведкой. Адреса кучи меняются при перезапуске,\n')
  f:write('; поэтому здесь только настройки проекции.\n')
  f:write(('fov=%d\n'):format(fov))
  f:write(('fwdAxis=%d\n'):format(fwdAxis))
  f:write(('upAxis=%d\n'):format(upAxis))
  f:write(('fwdSign=%d\n'):format(fwdSign))
  f:write(('mirrorX=%s\n'):format(tostring(mirrorX)))
  f:write(('mirrorY=%s\n'):format(tostring(mirrorY)))
  f:close()
  status = 'настройки проекции сохранены в config/recon.ini'
end

local function loadFound()
  local f = io.open(cfgPath, 'r')
  if not f then return end
  for line in f:lines() do
    local k, v = line:match('^(%w+)=(.*)$')
    if     k == 'fov'     then fov = tonumber(v) or fov
    elseif k == 'fwdAxis' then fwdAxis = tonumber(v) or fwdAxis
    elseif k == 'upAxis'  then upAxis = tonumber(v) or upAxis
    elseif k == 'fwdSign' then fwdSign = tonumber(v) or fwdSign
    elseif k == 'mirrorX' then mirrorX = (v == 'true')
    elseif k == 'mirrorY' then mirrorY = (v == 'true')
    end
  end
  f:close()
end

-- Ищет, откуда на найденный адрес показывает указатель. Если он окажется
-- внутри библиотеки, находка переживёт перезапуск игры.
local function tracePointers(addr, label)
  busy = 'ищу указатели…'
  local list, count = memory.findpointerto(addr, { range = 0x400 })
  busy = ''
  if not list then
    status = 'поиск указателей: ' .. tostring(count)
    return
  end
  log(('[разведка] на %s (0x%X) указывают %d мест:'):format(label, addr, count))
  local shown = 0
  for _, p in ipairs(list) do
    if p.where == 'модуль' then
      local base = memory.getclientbase()
      log(('   модуль +0x%X  -> смещение внутрь %d')
          :format(p.at - base, p.offset))
      shown = shown + 1
      if shown >= 12 then break end
    end
  end
  if shown == 0 then
    log('   ни одного указателя из самой библиотеки — только из кучи')
  end
  status = ('указателей на %s: %d, статических: %d (подробности в логе)')
           :format(label, count, shown)
end

-- ═══════════════════════════════════════════════════════════ отрисовка

local function drawOverlay()
  if camAddr == 0 or not showDots then return end
  local cam = memory.readmatrix(camAddr)
  if not cam then return end

  -- Точки на всех кандидатах: если проекция настроена верно, они лягут
  -- на реальные предметы в мире. Это и есть проверка настройки.
  --
  -- Позиции читаются одним пакетным вызовом: поштучно это было бы сотни
  -- системных вызовов на кадр и заметная просадка.
  local list = memory.readpositions(cands, dotLimit)
  if list then
    for _, o in ipairs(list) do
      local x, y, depth = worldToScreen(o.x, o.y, o.z, cam)
      if x and x > -50 and x < sw + 50 and y > -50 and y < sh + 50 then
        local far = depth > 60
        imgui.DrawCircleFilled(x, y, far and 3 or 5,
                               far and 0.4 or 1.0, far and 0.6 or 0.9,
                               1.0, far and 0.5 or 0.9)
      end
    end
  end

  if playerAddr ~= 0 then
    local pm = memory.readmatrix(playerAddr)
    if pm then
      local wx, wy, wz = pos(pm)
      local x, y = worldToScreen(wx, wy, wz, cam)
      if x then
        imgui.DrawCircleFilled(x, y, 12 * MDS, 0.2, 1.0, 0.3, 1.0)
        imgui.DrawText(x + 16 * MDS, y - 10 * MDS, 'игрок', 0.2, 1.0, 0.3, 1.0)
      end
    end
  end
end

-- ═════════════════════════════════════════════════════════════ интерфейс

local WIN_W, WIN_H = 940, 660
local LABEL_W = 280

local function label(text)
  imgui.AlignTextToFramePadding()
  imgui.Text(text)
  imgui.SameLine(LABEL_W)
  imgui.SetNextItemWidth(WIN_W - LABEL_W - 70)
end

local function title(text)
  imgui.Spacing()
  imgui.TextColored(text, 0.40, 0.85, 1.00, 1.0)
  imgui.Separator()
  imgui.Spacing()
end

local tab = 1
local TABS = { 'Поиск', 'Проекция', 'Найденное' }

local function tabSearch()
  title('Шаг 1 — снять слепок')
  imgui.TextWrapped(
    'Сканирует память и собирает всё, что похоже на матрицу положения. ' ..
    'Сюда попадут камера, игрок, транспорт и объекты вокруг.')
  imgui.TextDisabled('игра замрёт на пару секунд — это нормально')
  if imgui.Button('Сканировать', WIN_W - 70, 46) then doScan() end

  title('Шаг 2 — отделить камеру')
  imgui.TextWrapped(
    'Встаньте на месте и покрутите камеру, не двигаясь. Сдвинется только ' ..
    'она — остальное останется на месте.')
  if step >= 1 then
    if imgui.Button('Камера сдвинулась', WIN_W - 70, 46) then doCameraStep() end
  else
    imgui.TextDisabled('сначала «Сканировать»')
  end

  title('Шаг 3 — найти игрока')
  imgui.TextWrapped(
    'Теперь пройдите несколько шагов. Из того, что стояло на месте, ' ..
    'сдвинется ваш персонаж.')
  if step >= 2 then
    if imgui.Button('Я прошёл', WIN_W - 70, 46) then doPlayerStep() end
  else
    imgui.TextDisabled('сначала шаг 2')
  end

  imgui.Spacing()
  imgui.Separator()
  imgui.Spacing()
  if busy ~= '' then
    imgui.TextColored(busy, 1.0, 0.8, 0.2, 1.0)
  end
  imgui.TextWrapped(status)
end

local AXIS = { 'ось 1 (right)', 'ось 2 (up)', 'ось 3 (at)' }

local function tabProjection()
  if camAddr == 0 then
    imgui.TextColored('Сначала найдите камеру на вкладке «Поиск».',
                      1.0, 0.5, 0.4, 1.0)
    return
  end

  title('Настройка')
  imgui.TextWrapped(
    'Точки рисуются на всех найденных матрицах. Крутите параметры, пока ' ..
    'точки не лягут на реальные предметы вокруг — значит перевод мировых ' ..
    'координат в экранные считается верно.')

  imgui.Spacing()
  label('Показывать точки')
  local ch, v = imgui.Checkbox('##dots', showDots)
  if ch then showDots = v end

  label('Поле зрения')
  ch, v = imgui.SliderInt('##fov', fov, 30, 120, tostring(fov) .. '°')
  if ch then fov = v end

  label('Ось «вперёд»')
  ch, v = imgui.Combo('##fwd', fwdAxis, AXIS)
  if ch then fwdAxis = v end

  label('Ось «вверх»')
  ch, v = imgui.Combo('##up', upAxis, AXIS)
  if ch then upAxis = v end

  label('Развернуть «вперёд»')
  ch, v = imgui.Checkbox('##fsign', fwdSign < 0)
  if ch then fwdSign = v and -1 or 1 end

  label('Зеркалить по X')
  ch, v = imgui.Checkbox('##mx', mirrorX)
  if ch then mirrorX = v end

  label('Зеркалить по Y')
  ch, v = imgui.Checkbox('##my', mirrorY)
  if ch then mirrorY = v end

  label('Точек на экране')
  ch, v = imgui.SliderInt('##dl', dotLimit, 50, 2000)
  if ch then dotLimit = v end

  title('Проверка')
  local cam = memory.readmatrix(camAddr)
  if cam then
    local cx, cy, cz = pos(cam)
    label('Камера в мире')
    imgui.Text(('%.1f  %.1f  %.1f'):format(cx, cy, cz))
  end
  if playerAddr ~= 0 then
    local pm = memory.readmatrix(playerAddr)
    if pm then
      local px, py, pz = pos(pm)
      label('Игрок в мире')
      imgui.Text(('%.1f  %.1f  %.1f'):format(px, py, pz))
      if cam then
        local x, y, d = worldToScreen(px, py, pz, cam)
        label('Игрок на экране')
        if x then
          imgui.Text(('%.0f  %.0f   (до него %.1f м)'):format(x, y, d))
        else
          imgui.TextColored('за камерой — разверните ось «вперёд»',
                            1.0, 0.6, 0.3, 1.0)
        end
      end
    end
  end

  imgui.Spacing()
  if imgui.Button('Сохранить настройки', WIN_W - 70, 44) then saveFound() end
end

local function tabFound()
  title('Адреса этого запуска')
  label('База движка')
  imgui.Text(('0x%X'):format(memory.getclientbase() or 0))
  label('Камера')
  imgui.Text(camAddr ~= 0 and ('0x%X'):format(camAddr) or 'не найдена')
  label('Игрок')
  imgui.Text(playerAddr ~= 0 and ('0x%X'):format(playerAddr) or 'не найден')
  label('Кандидатов всего')
  imgui.Text(tostring(#cands))

  title('Сделать находку постоянной')
  imgui.TextWrapped(
    'Эти адреса в куче и при перезапуске игры станут другими. Чтобы ' ..
    'находка пережила перезапуск, нужен указатель на неё из самой ' ..
    'библиотеки: такой лежит на постоянном смещении от базы.')

  imgui.Spacing()
  if camAddr ~= 0 then
    if imgui.Button('Искать указатели на камеру', (WIN_W - 80) / 2, 44) then
      tracePointers(camAddr, 'камеру')
    end
    imgui.SameLine(0, 10)
  end
  if playerAddr ~= 0 then
    if imgui.Button('Искать указатели на игрока', (WIN_W - 80) / 2, 44) then
      tracePointers(playerAddr, 'игрока')
    end
  end

  imgui.Spacing()
  imgui.Separator()
  imgui.Spacing()
  imgui.TextWrapped(status)
end

function onImgui()
  refreshMetrics()
  drawOverlay()
  if not show then return end

  imgui.SetNextWindowSize(WIN_W, WIN_H, imgui.Cond_Always)
  imgui.SetNextWindowPos((sw - WIN_W) / 2, (sh - WIN_H) / 2,
                         imgui.Cond_FirstUseEver)

  local visible, open = imgui.Begin('Разведка движка', show,
    imgui.WindowFlags_NoResize + imgui.WindowFlags_NoCollapse)
  show = open

  if visible then
    local tw = (WIN_W - 40 - (#TABS - 1) * 8) / #TABS
    for i, name in ipairs(TABS) do
      if i > 1 then imgui.SameLine(0, 8) end
      if i == tab then
        imgui.PushStyleColor(imgui.Col_Button, 0.20, 0.55, 0.85, 1.0)
      else
        imgui.PushStyleColor(imgui.Col_Button, 0.16, 0.17, 0.20, 1.0)
      end
      if imgui.Button(name .. '##t' .. i, tw, 42) then tab = i end
      imgui.PopStyleColor()
    end
    imgui.Separator()

    if imgui.BeginChild('##body', 0, WIN_H - 150, false) then
      if     tab == 1 then tabSearch()
      elseif tab == 2 then tabProjection()
      else                 tabFound()
      end
    end
    imgui.EndChild()
  end
  imgui.End()
end

-- ═════════════════════════════════════════════════════════════════════ main

function main()
  refreshMetrics()
  loadFound()

  registerChatCommand('recon', function() show = not show end)
  log('разведка готова: /recon')

  while true do wait(1000) end
end
