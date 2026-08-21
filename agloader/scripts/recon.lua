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
local TABS   = { 'Игрок', 'Игроки', 'Камера', 'Проекция' }
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
  local f = io.open(cfgPath, 'w')
  if not f then return end
  f:write(('fov=%d\nfwdAxis=%d\nupAxis=%d\nfwdSign=%d\nmirrorX=%s\nmirrorY=%s\n')
          :format(fov, fwdAxis, upAxis, fwdSign,
                  tostring(mirrorX), tostring(mirrorY)))
  f:close()
  status = 'настройки сохранены'
end

local function loadCfg()
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
      else                 tabProjection()
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
