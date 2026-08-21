-- Разведка движка: игрок, игроки вокруг, камера и проекция.
--
-- Открыть: /recon
--
-- Данные игрока берутся по адресам, вытащенным разбором libag-client.so —
-- см. lib/arizona.lua, там расписано откуда. Камера в коде не нашлась, но
-- её можно найти на живой игре: она единственная матрица, которая стоит
-- рядом с игроком и смотрит прямо на него. Это и делает кнопка автопоиска,
-- заодно определяя, какая из осей матрицы означает «вперёд».

script_name('Разведка движка')
script_author('agloader')
script_version('2.0')

local ag = require 'arizona'

local MDS, sw, sh = 1, 1280, 720

local function refreshMetrics()
  local s = getUiScale()
  if s and s > 0 then MDS = s end
  local w, h = getScreenSize()
  if w and w > 0 then sw, sh = w, h end
end

-- ═══════════════════════════════════════════════════════════════ состояние

local show   = false
local tab    = 1
local TABS   = { 'Игрок', 'Игроки', 'Камера', 'Проекция', 'Пулы', 'Слот', 'Объект', 'Сеть' }
local status = ''

local cands   = {}
local camAddr = 0

local fov     = 70
local fwdAxis = 2
local upAxis  = 3
local fwdSign = 1
local mirrorX = false
local mirrorY = false

local espPlayers = false
local espDist    = 300

local cfgPath = getPaths().config .. '/recon.ini'

-- Разведчик структуры: адрес, окно просмотра и последний снимок.
local insAddr   = ''
local insOffset = 0
local insSize   = 512
local insRows   = {}
local insOnlyText = false
local insNote   = 'выберите объект и нажмите «Прочитать»'

-- Проверка сети.
-- Пул сущностей мира.
local poolNote  = 'нажмите «Найти смещение позиции»'
local poolList  = {}
local poolTypes = {}

local netUrl    = 'https://api.github.com/zen'
local netState  = 'не запускали'
local netBody   = ''
local netBusy   = false

-- ═════════════════════════════════════════════════════ матрица и проекция

local function row(m, i)
  local o = (i - 1) * 4
  return m[o + 1], m[o + 2], m[o + 3]
end

local function mpos(m) return m[13], m[14], m[15] end

local function dot3(ax, ay, az, bx, by, bz)
  return ax * bx + ay * by + az * bz
end

local function norm3(x, y, z)
  local len = math.sqrt(x * x + y * y + z * z)
  if len < 1e-6 then return 0, 0, 0, 0 end
  return x / len, y / len, z / len, len
end

local function worldToScreen(wx, wy, wz, cam)
  local px, py, pz = mpos(cam)
  local dx, dy, dz = wx - px, wy - py, wz - pz

  local fx, fy, fz = row(cam, fwdAxis)
  fx, fy, fz = fx * fwdSign, fy * fwdSign, fz * fwdSign
  local ux, uy, uz = row(cam, upAxis)

  -- Правая ось через векторное произведение — так она всегда согласована
  -- с выбранными «вперёд» и «вверх».
  local rx = fy * uz - fz * uy
  local ry = fz * ux - fx * uz
  local rz = fx * uy - fy * ux

  local depth = dot3(dx, dy, dz, fx, fy, fz)
  if depth <= 0.05 then return nil end

  local hx = dot3(dx, dy, dz, rx, ry, rz)
  local hy = dot3(dx, dy, dz, ux, uy, uz)

  local tanHalf = math.tan(math.rad(fov) / 2)
  local nx = hx / (depth * tanHalf * (sw / sh))
  local ny = hy / (depth * tanHalf)
  if mirrorX then nx = -nx end
  if mirrorY then ny = -ny end

  return sw / 2 + nx * (sw / 2), sh / 2 - ny * (sh / 2), depth
end

-- ═══════════════════════════════════════════════════════ поиск камеры

local function scanMatrices()
  local list, count = memory.findmatrix({ tol = 0.01, limit = 20000 })
  if not list then
    status = 'ошибка поиска: ' .. tostring(count)
    return false
  end
  cands = list
  status = ('найдено матриц: %d'):format(count)
  log('[разведка] ' .. status)
  return true
end

-- Камера стоит рядом с игроком и смотрит на него. Проверяем все три оси в
-- обе стороны: та, что указывает на игрока, и есть «вперёд».
local function autoFindCamera()
  local me = ag.localPlayer()
  if not me then
    status = 'игрок не найден — движок ещё не прогрузился?'
    return
  end
  local px, py, pz = ag.position(me)
  if not px then
    status = 'позиция игрока не читается'
    return
  end

  if #cands == 0 and not scanMatrices() then return end

  local best, bestDot, bestAxis, bestSign, bestDist = 0, 0.90, 0, 1, 0

  for _, addr in ipairs(cands) do
    local m = memory.readmatrix(addr)
    if m then
      local cx, cy, cz = mpos(m)
      local tx, ty, tz, dist = norm3(px - cx, py - cy, pz - cz)
      -- Слишком близко — это сам игрок, слишком далеко — не наша камера.
      if dist > 0.7 and dist < 40 then
        for axis = 1, 3 do
          local ax, ay, az = row(m, axis)
          for _, sign in ipairs({ 1, -1 }) do
            local d = dot3(ax * sign, ay * sign, az * sign, tx, ty, tz)
            if d > bestDot then
              best, bestDot, bestAxis, bestSign, bestDist =
                addr, d, axis, sign, dist
            end
          end
        end
      end
    end
  end

  if best == 0 then
    status = 'камера не опознана. Попробуйте от третьего лица и не в меню, ' ..
             'затем «Пересканировать память»'
    return
  end

  camAddr, fwdAxis, fwdSign = best, bestAxis, bestSign

  -- «Вверх» — из двух оставшихся осей та, что ближе к мировой вертикали.
  local cm = memory.readmatrix(camAddr)
  local bestUp, bestUpZ = 0, -2
  for axis = 1, 3 do
    if axis ~= fwdAxis then
      local _, _, az = row(cm, axis)
      if az > bestUpZ then bestUp, bestUpZ = axis, az end
    end
  end
  upAxis = bestUp

  -- Находку отдаём библиотеке: её же читают остальные скрипты.
  ag.cam.addr, ag.cam.fwdAxis, ag.cam.fwdSign = camAddr, fwdAxis, fwdSign
  ag.cam.upAxis = upAxis

  status = ('камера: 0x%X, до игрока %.1f м, точность %.3f. ' ..
            'Ось «вперёд» %d (%s), «вверх» %d')
           :format(camAddr, bestDist, bestDot, fwdAxis,
                   fwdSign > 0 and '+' or '-', upAxis)
  log('[разведка] ' .. status)
end

-- Игрок должен проецироваться примерно в центр экрана. Если по X он ушёл
-- в сторону — правая ось смотрит не туда, это лечится зеркалом.
local function autoFixMirror()
  local me = ag.localPlayer()
  local cam = camAddr ~= 0 and memory.readmatrix(camAddr) or nil
  if not me or not cam then return end
  local px, py, pz = ag.position(me)
  if not px then return end

  local x = worldToScreen(px, py, pz, cam)
  if not x then
    status = 'игрок за камерой — сначала разверните ось «вперёд»'
    return
  end
  if math.abs(x - sw / 2) > sw * 0.25 then
    mirrorX = not mirrorX
    status = 'зеркало по X переключено'
  else
    status = 'игрок и так близко к центру, зеркало не нужно'
  end
end

-- ══════════════════════════════════════════════════════════════ конфиг

local function saveCfg()
  -- Пишем через библиотеку, чтобы файл был один на всех и остальные скрипты
  -- подхватывали настройки без своей копии разбора.
  ag.cam.fov, ag.cam.fwdAxis, ag.cam.upAxis = fov, fwdAxis, upAxis
  ag.cam.fwdSign, ag.cam.mirrorX, ag.cam.mirrorY = fwdSign, mirrorX, mirrorY
  if ag.saveProjection() then
    status = 'настройки сохранены, их подхватят другие скрипты'
  else
    status = 'не удалось записать файл настроек'
  end
end

local function loadCfg()
  if not ag.loadProjection() then return end
  local c = ag.cam
  fov, fwdAxis, upAxis = c.fov, c.fwdAxis, c.upAxis
  fwdSign, mirrorX, mirrorY = c.fwdSign, c.mirrorX, c.mirrorY
end

-- ═══════════════════════════════════════════════════════════ отрисовка

local function drawEsp()
  if not espPlayers or camAddr == 0 then return end
  local cam = memory.readmatrix(camAddr)
  if not cam then return end

  local me = ag.localPlayer()
  local mx, my, mz
  if me then mx, my, mz = ag.position(me) end

  for _, p in ipairs(ag.players({ skipLocal = true })) do
    local x, y, depth = worldToScreen(p.x, p.y, p.z, cam)
    if x and x > -100 and x < sw + 100 and y > -100 and y < sh + 100
       and depth < espDist then
      local dist = mx and getDistanceBetweenCoords3d(mx, my, mz, p.x, p.y, p.z)
                   or depth
      local r, g, b = 0.3, 1.0, 0.4
      if p.inVehicle then r, g, b = 1.0, 0.8, 0.2 end

      imgui.DrawCircleFilled(x, y, 6 * MDS, r, g, b, 0.95)
      local text = ('%d  %.0fм'):format(p.index, dist)
      imgui.DrawText(x + 10 * MDS, y - 8 * MDS, text, 0, 0, 0, 0.7)
      imgui.DrawText(x + 9 * MDS, y - 9 * MDS, text, r, g, b, 1.0)
    end
  end
end

-- ═════════════════════════════════════════════════════════════ интерфейс

local WIN_W, WIN_H = 960, 680
local LABEL_W = 300

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

local function tabLocal()
  title('Свой игрок')

  if not ag.available() then
    imgui.TextColored('движок не найден', 1.0, 0.4, 0.4, 1.0)
    return
  end

  local idx = ag.localIndex()
  label('Слот')
  imgui.Text(idx and tostring(idx) or 'нет (0xFFFF)')

  local me = ag.localPlayer()
  label('Объект')
  imgui.Text(me and ('0x%X'):format(me) or 'не получен')

  if me then
    local x, y, z = ag.position(me)
    label('Позиция')
    imgui.Text(x and ('%.2f   %.2f   %.2f'):format(x, y, z) or 'не читается')

    label('В транспорте')
    if ag.inVehicle(me) then
      imgui.TextColored(('да, 0x%X'):format(ag.vehiclePtr(me)),
                        0.3, 1.0, 0.4, 1.0)
    else
      imgui.TextDisabled('нет')
    end

    label('Скорость')
    imgui.Text(('%.1f км/ч'):format(ag.speedKmh(me)))

    local vx, vy, vz = ag.velocity(me)
    label('Вектор скорости')
    imgui.Text(vx and ('%.3f  %.3f  %.3f'):format(vx, vy, vz) or '—')
  end

  title('Откуда адреса')
  imgui.TextWrapped(
    'Разбор экспортируемого движком метода getLocalVehicleSpeed дал всю ' ..
    'цепочку: индекс своего слота, массив игроков с шагом 336 байт и ' ..
    'смещения полей. Подробности — в комментариях lib/arizona.lua.')

  label('Массив игроков')
  imgui.Text(('база +0x%X'):format(ag.OFF_PLAYER_ARRAY))
  label('Индекс своего слота')
  imgui.Text(('база +0x%X'):format(ag.OFF_LOCAL_INDEX))
  label('Позиция в объекте')
  imgui.Text(('+%d'):format(ag.OFF_POS))
end

local function tabPlayers()
  title('Игроки рядом')

  local me = ag.localPlayer()
  local mx, my, mz
  if me then mx, my, mz = ag.position(me) end

  local list = ag.players({ skipLocal = true })
  label('Найдено')
  imgui.Text(tostring(#list))

  imgui.Spacing()
  if imgui.BeginChild('##pl', 0, WIN_H - 320, true) then
    if #list == 0 then
      imgui.TextDisabled('пусто — либо рядом никого, либо движок не прогрузился')
    end
    -- Ближайшие сверху: так список полезнее.
    if mx then
      table.sort(list, function(a, b)
        local da = getDistanceBetweenCoords3d(mx, my, mz, a.x, a.y, a.z)
        local db = getDistanceBetweenCoords3d(mx, my, mz, b.x, b.y, b.z)
        return da < db
      end)
    end
    for i, p in ipairs(list) do
      if i > 60 then break end
      local d = mx and getDistanceBetweenCoords3d(mx, my, mz, p.x, p.y, p.z) or 0
      local line = ('слот %-5d %8.1f м   %.0f %.0f %.0f%s')
                   :format(p.index, d, p.x, p.y, p.z,
                           p.inVehicle and '   в транспорте' or '')
      if p.inVehicle then
        imgui.TextColored(line, 1.0, 0.8, 0.2, 1.0)
      else
        imgui.Text(line)
      end
    end
  end
  imgui.EndChild()
end

local function tabCamera()
  title('Поиск камеры')
  imgui.TextWrapped(
    'Камера ищется автоматически: она стоит в нескольких метрах от игрока ' ..
    'и смотрит прямо на него. Встаньте от третьего лица, закройте игровые ' ..
    'меню и нажмите кнопку. Сканирование памяти займёт пару секунд, игра ' ..
    'на это время замрёт.')

  imgui.Spacing()
  if imgui.Button('Найти камеру', WIN_W - 70, 48) then autoFindCamera() end
  imgui.Spacing()
  if imgui.Button('Пересканировать память', (WIN_W - 80) / 2, 44) then
    cands = {}
    scanMatrices()
  end
  imgui.SameLine(0, 10)
  if imgui.Button('Поправить зеркало', (WIN_W - 80) / 2, 44) then
    autoFixMirror()
  end

  title('Результат')
  label('Матриц-кандидатов')
  imgui.Text(tostring(#cands))
  label('Камера')
  imgui.Text(camAddr ~= 0 and ('0x%X'):format(camAddr) or 'не найдена')

  if camAddr ~= 0 then
    local cm = memory.readmatrix(camAddr)
    if cm then
      local cx, cy, cz = mpos(cm)
      label('Камера в мире')
      imgui.Text(('%.1f  %.1f  %.1f'):format(cx, cy, cz))
    end
  end

  imgui.Spacing()
  imgui.TextWrapped(status)
end

local function tabProjection()
  if camAddr == 0 then
    imgui.TextColored('Сначала найдите камеру.', 1.0, 0.5, 0.4, 1.0)
    return
  end

  title('Проверка на игроках')
  imgui.TextWrapped(
    'Включите отметки и посмотрите на людей вокруг: если кружки держатся ' ..
    'на них при повороте камеры — проекция настроена верно. Если ползут ' ..
    'в сторону, крутите поле зрения.')

  imgui.Spacing()
  label('Отметки игроков')
  local ch, v = imgui.Checkbox('##esp', espPlayers)
  if ch then espPlayers = v end

  label('Дальность отметок')
  ch, v = imgui.SliderInt('##ed', espDist, 20, 1000, tostring(espDist) .. ' м')
  if ch then espDist = v end

  title('Настройка')
  label('Поле зрения')
  ch, v = imgui.SliderInt('##fov', fov, 30, 120, tostring(fov) .. '°')
  if ch then fov = v end

  local AXIS = { 'ось 1', 'ось 2', 'ось 3' }
  label('Ось «вперёд»')
  ch, v = imgui.Combo('##fwd', fwdAxis, AXIS)
  if ch then fwdAxis = v end

  label('Ось «вверх»')
  ch, v = imgui.Combo('##up', upAxis, AXIS)
  if ch then upAxis = v end

  label('Развернуть «вперёд»')
  ch, v = imgui.Checkbox('##fs', fwdSign < 0)
  if ch then fwdSign = v and -1 or 1 end

  label('Зеркалить по X')
  ch, v = imgui.Checkbox('##mx', mirrorX)
  if ch then mirrorX = v end

  label('Зеркалить по Y')
  ch, v = imgui.Checkbox('##my', mirrorY)
  if ch then mirrorY = v end

  title('Куда попадает свой игрок')
  local me = ag.localPlayer()
  local cam = memory.readmatrix(camAddr)
  if me and cam then
    local px, py, pz = ag.position(me)
    if px then
      local x, y, d = worldToScreen(px, py, pz, cam)
      label('На экране')
      if x then
        imgui.Text(('%.0f  %.0f   (центр: %.0f %.0f)')
                   :format(x, y, sw / 2, sh / 2))
      else
        imgui.TextColored('за камерой — разверните «вперёд»', 1.0, 0.6, 0.3, 1.0)
      end
      label('До камеры')
      imgui.Text(d and ('%.1f м'):format(d) or '—')
    end
  end

  imgui.Spacing()
  if imgui.Button('Сохранить настройки', WIN_W - 70, 44) then saveCfg() end
  imgui.Spacing()
  imgui.TextWrapped(status)
end

local function tabPool()
  title('Пулы сущностей мира')
  imgui.TextWrapped(
    'Сущности движок держит тремя пулами, и в библиотеке лежит не сам ' ..
    'массив, а указатель на него: массив выделен в куче и переезжает при ' ..
    'каждом запуске. Пределы мест взяты из кода, там же рядом с ними стоит ' ..
    'чтение позиции по +56 — то же смещение, что у игрока.')

  imgui.Spacing()
  label('Смещение позиции')
  if ag.poolPosOffset then
    imgui.TextColored(('+%d'):format(ag.poolPosOffset), 0.3, 1.0, 0.4, 1.0)
  else
    imgui.TextDisabled('не подтверждено')
  end

  imgui.Separator()
  for n = 1, #ag.POOLS do
    local def = ag.POOLS[n]
    local addr, count = ag.poolArray(n)
    imgui.Text(('%-10s база +0x%X'):format(def.name, def.global))
    imgui.SameLine(260 * MDS)
    if addr then
      imgui.TextColored(('0x%X, мест %d'):format(addr, count), 0.3, 1.0, 0.4, 1)
    else
      imgui.TextDisabled('не выделен')
    end
  end

  imgui.Spacing()
  if imgui.Button('Проверить смещение позиции', WIN_W - 70, 44) then
    local me = ag.localPlayer()
    if not me then
      poolNote = 'игрок не найден'
    else
      local px, py, pz = ag.position(me)
      if not px then
        poolNote = 'позиция игрока не читается'
      else
        local off, hits, sample = ag.findPoolPositionOffset(px, py, pz)
        if off then
          poolNote = ('смещение +%d, подтвердили %d сущностей из %d')
                     :format(off, hits, sample)
          ag.saveProjection()
          log('[разведка] ' .. poolNote)
        else
          poolNote = ('не подтвердилось: лучший результат %d из %d')
                     :format(hits or 0, sample or 0)
        end
      end
    end
  end

  imgui.Spacing()
  if imgui.Button('Пересчитать список', WIN_W - 70, 44) then
    local me = ag.localPlayer()
    local px, py, pz = me and ag.position(me)
    poolList = ag.entities({
      near = px and { px, py, pz } or nil,
      radius = 300, max = 400,
    })
    poolTypes = {}
    for _, o in ipairs(poolList) do
      local key = o.poolName or '?'
      poolTypes[key] = (poolTypes[key] or 0) + 1
    end
    poolNote = ('в списке: %d'):format(#poolList)
  end

  imgui.Spacing()
  imgui.TextWrapped(poolNote)

  if next(poolTypes) then
    imgui.Separator()
    local parts = {}
    for t, c in pairs(poolTypes) do
      parts[#parts + 1] = ('%s: %d'):format(t, c)
    end
    table.sort(parts)
    imgui.TextWrapped(table.concat(parts, '   '))
  end

  imgui.Separator()
  if imgui.BeginChild('##pool', 0, WIN_H - 520, true) then
    if #poolList == 0 then
      imgui.TextDisabled('список пуст')
    end
    table.sort(poolList, function(a, b)
      return (a.dist or 1e9) < (b.dist or 1e9)
    end)
    for i, o in ipairs(poolList) do
      if i > 80 then break end
      local _, mtype = ag.modelInfo(o.model)
      imgui.Text(('%-9s #%-5d модель %-6d тип %-3d %s')
                 :format(o.poolName or '?', o.index, o.model or -1,
                         mtype or -1,
                         o.dist and ('%.1f м'):format(o.dist) or ''))
    end
  end
  imgui.EndChild()
end

-- ─────────────────────────────────────────────────────── слот игрока

local slotTexts = {}
local slotNote  = ''
local nickInput = ''

local function tabSlot()
  title('Слот игрока: ник и прочие подписи')
  imgui.TextWrapped(
    'Слот игрока — 336 байт, из которых указатель на сущность занимает ' ..
    'только первые восемь. Остальное чем-то занято, и ник почти наверняка ' ..
    'там же. Кнопка ниже перебирает весь слот и показывает всё, что похоже ' ..
    'на текст: и строки прямо в слоте, и строки по указателю. Узнайте себя ' ..
    'в списке — или впишите ник и найдите смещение сразу.')

  imgui.Spacing()
  label('Свой слот')
  local me = ag.localIndex()
  imgui.Text(me and tostring(me) or 'не определён')
  label('Смещение ника')
  if ag.nickOffset then
    imgui.TextColored(('+%d'):format(ag.nickOffset), 0.3, 1.0, 0.4, 1.0)
  else
    imgui.TextDisabled('не найдено')
  end

  imgui.Spacing()
  imgui.SetNextItemWidth(WIN_W - 220 * MDS)
  local ch, v = imgui.InputText('##nick', nickInput, 32)
  if ch then nickInput = v end
  imgui.SameLine()
  if imgui.Button('Найти по нику', 180 * MDS, 0) then
    if nickInput == '' then
      slotNote = 'впишите свой ник как он написан в игре'
    else
      local off, kind = ag.findNickOffset(nickInput)
      if off then
        slotNote = ('ник найден: +%d (%s)'):format(off, kind)
        ag.saveProjection()
        log('[разведка] ' .. slotNote)
      else
        slotNote = 'такого текста в слоте нет: ' .. tostring(kind)
      end
    end
  end

  imgui.Spacing()
  if imgui.Button('Показать весь текст слота', WIN_W - 70, 44) then
    local a = ag.slotAddr(me)
    if not a then
      slotNote = 'слот не определён'
    else
      slotTexts = ag.findTexts(a, ag.SLOT_STRIDE)
      slotNote = ('найдено текстов: %d'):format(#slotTexts)
    end
  end

  imgui.Spacing()
  imgui.TextWrapped(slotNote)
  imgui.Separator()

  if imgui.BeginChild('##slot', 0, WIN_H - 470, true) then
    if #slotTexts == 0 then
      imgui.TextDisabled('пусто — нажмите кнопку выше')
    end
    for _, t in ipairs(slotTexts) do
      imgui.Text(('+%-4d %-11s %s'):format(t.off, t.kind, t.text))
    end
  end
  imgui.EndChild()
end

local function tabInspect()
  title('Что лежит в объекте')
  imgui.TextWrapped(
    'Показывает память по восемь байт: как числа, как дробные и как текст. ' ..
    'Короткие строки C++ лежат прямо внутри объекта, длинные — по указателю, ' ..
    'поэтому пробуются оба варианта. Так ищутся поля, которых не видно в ' ..
    'разборе кода: ник, номер, здоровье.')

  imgui.Spacing()
  label('Адрес')
  local ch, v = imgui.InputText('##ia', insAddr, 32)
  if ch then insAddr = v end

  if imgui.Button('Взять свой объект', (WIN_W - 80) / 2, 40) then
    local me = ag.localPlayer()
    insAddr = me and ('0x%X'):format(me) or ''
    insNote = me and 'адрес подставлен' or 'игрок не найден'
  end
  imgui.SameLine(0, 10)
  if imgui.Button('Взять свой транспорт', (WIN_W - 80) / 2, 40) then
    local me = ag.localPlayer()
    local veh = me and ag.vehiclePtr(me)
    insAddr = veh and ('0x%X'):format(veh) or ''
    insNote = veh and 'адрес транспорта подставлен' or 'вы не в транспорте'
  end

  label('Смещение от начала')
  ch, v = imgui.InputInt('##io', insOffset, 64)
  if ch then insOffset = math.max(0, v) end

  label('Сколько байт')
  ch, v = imgui.SliderInt('##is', insSize, 64, 2048, tostring(insSize))
  if ch then insSize = v end

  label('Только со строками')
  ch, v = imgui.Checkbox('##it', insOnlyText)
  if ch then insOnlyText = v end

  imgui.Spacing()
  if imgui.Button('Прочитать', WIN_W - 70, 44) then
    local a = tonumber(insAddr)
    if not a then
      insNote = 'адрес не разобран'
      insRows = {}
    else
      local rows, n = memory.inspect(a + insOffset, insSize)
      if not rows then
        insNote = 'не прочиталось: ' .. tostring(n)
        insRows = {}
      else
        insRows = rows
        insNote = ('прочитано строк: %d, от +%d'):format(n, insOffset)
      end
    end
  end

  imgui.Spacing()
  imgui.TextWrapped(insNote)
  imgui.Separator()

  if imgui.BeginChild('##ins', 0, WIN_H - 470, true) then
    for _, r in ipairs(insRows) do
      local interesting = r.text or r.deref
      if not insOnlyText or interesting then
        local off = insOffset + r.off
        local line = ('+%-6d %s'):format(off, r.hex)
        if r.f0 and math.abs(r.f0) > 0.0001 and math.abs(r.f0) < 1e6 then
          line = line .. ('   %.3f'):format(r.f0)
        end
        if r.i0 ~= 0 and (r.i0 > -100000 and r.i0 < 100000) then
          line = line .. ('   [%d]'):format(r.i0)
        end

        if r.text then
          imgui.TextColored(line .. '   «' .. r.text .. '»', 0.4, 1.0, 0.5, 1.0)
        elseif r.deref then
          imgui.TextColored(line .. '   -> «' .. r.deref .. '»',
                            1.0, 0.85, 0.3, 1.0)
        else
          imgui.Text(line)
        end
      end
    end
    if #insRows == 0 then
      imgui.TextDisabled('пусто')
    end
  end
  imgui.EndChild()
end

local function tabNet()
  title('Проверка сети')
  imgui.TextWrapped(
    'Запросы идут через системный стек Android, поэтому HTTPS работает без ' ..
    'дополнительных библиотек. Сам запрос уходит в фоновый поток, игра на ' ..
    'нём не висит.')

  imgui.Spacing()
  label('Адрес')
  local ch, v = imgui.InputText('##nu', netUrl, 256)
  if ch then netUrl = v end

  if imgui.Button('Запросить', WIN_W - 70, 44) and not netBusy then
    netBusy = true
    netState = 'запрос пошёл…'
    netBody = ''
    -- В отдельной корутине: сам вызов внутри ждёт ответа через wait().
    lua_thread.create(function()
      local requests = require 'requests'
      local r = requests.get(netUrl)
      netBusy = false
      if r.error then
        netState = 'ошибка: ' .. tostring(r.error)
      else
        netState = ('код %d, байт %d'):format(r.status_code, #r.text)
        netBody = r.text:sub(1, 2000)
      end
    end)
  end

  imgui.Spacing()
  label('Состояние')
  imgui.Text(netState)
  label('Запросов в работе')
  imgui.Text(tostring(net.pending()))

  if netBody ~= '' then
    imgui.Separator()
    if imgui.BeginChild('##nb', 0, WIN_H - 480, true) then
      imgui.TextWrapped(netBody)
    end
    imgui.EndChild()
  end
end

function onImgui()
  refreshMetrics()
  drawEsp()
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
      if     tab == 1 then tabLocal()
      elseif tab == 2 then tabPlayers()
      elseif tab == 3 then tabCamera()
      elseif tab == 4 then tabProjection()
      elseif tab == 5 then tabPool()
      elseif tab == 6 then tabSlot()
      elseif tab == 7 then tabInspect()
      else                 tabNet()
      end
    end
    imgui.EndChild()
  end
  imgui.End()
end

function main()
  refreshMetrics()
  loadCfg()

  registerChatCommand('recon', function() show = not show end)
  log('разведка готова: /recon')

  -- Ждём, пока движок выдаст игрока, и сразу пишем находку в лог: так
  -- видно, работают ли статические адреса, даже не открывая меню.
  while true do
    local me = ag.localPlayer()
    if me then
      local x, y, z = ag.position(me)
      if x then
        log(('[разведка] игрок в слоте %d, объект 0x%X, позиция %.1f %.1f %.1f')
            :format(ag.localIndex() or -1, me, x, y, z))
        break
      end
    end
    wait(2000)
  end

  while true do wait(5000) end
end
