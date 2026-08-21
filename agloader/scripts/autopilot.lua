-- Автопилот: ведёт персонажа к точке сам.
--
--   /ap            меню
--   /apgo дом      идти к точке из /wp
--   /apgo 100 -200 идти к координатам
--   /apstop        остановиться
--
-- Управление в игре экранное, поэтому автопилот не лезет в потроха
-- движка: он нажимает джойстик ровно там же, где его нажимает палец.
-- Куда толкать — считается из положения игрока и разворота камеры,
-- которые движок отдаёт честно.
--
-- Где джойстик, скрипт не угадывает: нажмите «Записать джойстик» и один
-- раз проведите пальцем как обычно — центр и радиус запомнятся.

script_name('AutoPilot')
script_author('AGLoader')
script_version('1.0')

local ag = require 'arizona'

local MDS, sw, sh = 1, 1280, 720

-- ═══════════════════════════════════════════════════════════ состояние

local menuOpen = false
local active   = false

local target   = nil          -- { x, y, z, name }
local arriveAt = 3.0          -- метров до цели
local status   = 'стоим'

-- Джойстик: доли экрана, чтобы настройка пережила смену разрешения.
local stick = { x = 0.20, y = 0.72, r = 0.075 }
local recording = false
local recDown   = nil
local recMax    = 0

-- Палец у автопилота свой, чтобы не спорить с настоящим.
local FINGER = 7
local held   = false

local lastX, lastY, lastZ
local stuckFor, unstickUntil = 0, 0

local cfgPath = getPaths().config .. '/autopilot.ini'

local function saveCfg()
  local f = io.open(cfgPath, 'w')
  if not f then return end
  f:write(('stickX=%f\nstickY=%f\nstickR=%f\narrive=%f\n')
          :format(stick.x, stick.y, stick.r, arriveAt))
  f:close()
end

local function loadCfg()
  local f = io.open(cfgPath, 'r')
  if not f then return end
  for line in f:lines() do
    local k, v = line:match('^(%w+)=(.*)$')
    v = tonumber(v)
    if v then
      if     k == 'stickX' then stick.x = v
      elseif k == 'stickY' then stick.y = v
      elseif k == 'stickR' then stick.r = v
      elseif k == 'arrive' then arriveAt = v end
    end
  end
  f:close()
end

-- ═════════════════════════════════════════════════════════════ касания

local function stickCenter()
  return stick.x * sw, stick.y * sh
end

local function stickRadius()
  return stick.r * sw
end

-- Толкнуть джойстик в сторону (dx, dy) — доли от единицы, экранные оси.
local function push(dx, dy)
  local cx, cy = stickCenter()
  local r = stickRadius()
  local px, py = cx + dx * r, cy + dy * r

  if not held then
    touch(0, FINGER, cx, cy)     -- палец опустился в центр
    held = true
  end
  touch(2, FINGER, px, py)       -- и повёл
end

local function release()
  if held then
    local cx, cy = stickCenter()
    touch(1, FINGER, cx, cy)
    held = false
  end
end

-- ══════════════════════════════════════════════════════════ навигация

-- Куда толкать джойстик, чтобы идти в мировую сторону (dx, dy).
--
-- Джойстик задаёт направление относительно камеры: вверх — от камеры
-- вперёд. Значит мировое направление надо разложить по осям камеры.
-- Направление камеры берётся из её кадра, который движок обновляет сам.
local function stickFor(dx, dy)
  local _, _, _, ax, ay = ag.cameraPose()
  if not ax then return nil end

  -- Смотрим сверху, поэтому вертикальная составляющая камеры не нужна.
  local len = math.sqrt(ax * ax + ay * ay)
  if len < 0.001 then return nil end
  local fx, fy = ax / len, ay / len
  -- Правая ось на плоскости — поворот «вперёд» на девяносто градусов.
  local rx, ry = fy, -fx

  local dlen = math.sqrt(dx * dx + dy * dy)
  if dlen < 0.001 then return 0, 0 end
  local nx, ny = dx / dlen, dy / dlen

  local forward = fx * nx + fy * ny
  local side    = rx * nx + ry * ny

  -- Экранные оси: вправо — плюс, вверх — минус.
  return side, -forward
end

local function stop(why)
  active = false
  target = nil
  release()
  status = why or 'стоим'
  notify('[AutoPilot] ' .. status, 4)
end

local function step()
  if not active or not target then return end

  local me = ag.localPlayer()
  if not me then status = 'игрок не найден'; release(); return end
  local x, y, z = ag.position(me)
  if not x then status = 'позиция не читается'; release(); return end

  local d = getDistanceBetweenCoords3d(x, y, z, target.x, target.y, target.z)
  if d <= arriveAt then
    stop(('пришли к «%s», %.1f м'):format(target.name or 'точке', d))
    return
  end

  local sx, sy = stickFor(target.x - x, target.y - y)
  if not sx then
    status = 'камера не найдена'
    release()
    return
  end

  -- Застряли — упёрлись в стену или забор. Отходим и берём вбок: без
  -- этого автопилот будет вечно тереться о препятствие.
  local now = os.clock()
  if lastX then
    local moved = getDistanceBetweenCoords3d(x, y, z, lastX, lastY, lastZ)
    if moved < 0.15 then
      stuckFor = stuckFor + 1
    else
      stuckFor = 0
    end
  end
  lastX, lastY, lastZ = x, y, z

  if stuckFor > 12 and now > unstickUntil then
    unstickUntil = now + 1.2
    stuckFor = 0
  end
  if now < unstickUntil then
    sx, sy = -sy, sx      -- уходим вбок, пока не отлипнем
  end

  push(sx, sy)
  status = ('идём к «%s», %.0f м, %.0f км/ч')
           :format(target.name or 'точке', d, ag.speedKmh(me) or 0)
end

-- ═══════════════════════════════════════════════════════════════ цели

local function waypoints()
  local out = {}
  local f = io.open(getPaths().config .. '/waypoints.ini', 'r')
  if not f then return out end
  for line in f:lines() do
    local k, v = line:match('^([^=]+)=(.*)$')
    if k and v then
      local x, y, z = v:match('^(-?[%d%.]+) (-?[%d%.]+) (-?[%d%.]+)$')
      if x then
        out[#out + 1] = { name = k, x = tonumber(x), y = tonumber(y),
                          z = tonumber(z) }
      end
    end
  end
  f:close()
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

local function goTo(t)
  target = t
  active = true
  stuckFor, unstickUntil = 0, 0
  lastX = nil
  notify(('[AutoPilot] идём к «%s»'):format(t.name or 'точке'), 4)
end

-- ══════════════════════════════════════════════════════════════ меню

local function drawStickHint()
  if not (menuOpen or recording) then return end
  local cx, cy = stickCenter()
  local r = stickRadius()
  local a = recording and 0.9 or 0.35
  imgui.DrawCircle(cx, cy, r, 0.2, 0.9, 1.0, a, 2.0)
  imgui.DrawCircleFilled(cx, cy, 5 * MDS, 0.2, 0.9, 1.0, a)
  imgui.DrawText(cx - 40 * MDS, cy - r - 18 * MDS,
                 recording and 'ведите джойстик' or 'джойстик',
                 0.2, 0.9, 1.0, a)
end

-- Запись джойстика: где палец опустился — там центр, куда увели —
-- радиус. Одно движение, и настраивать больше нечего.
--
-- Возвращать отсюда false нельзя ни в коем случае: в загрузчике, как и в
-- MoonLoader, явный false означает «касание поглощено». Скрипт, который
-- вернул его на каждое касание, отбирает у игры весь ввод — ни идти, ни
-- чат открыть. Поэтому здесь либо ничего не возвращается, либо true.
function onTouch(action, id, x, y)
  if not recording then return end
  if action == 0 then
    recDown = { x = x, y = y }
    recMax = 0
  elseif action == 2 and recDown then
    local dx, dy = x - recDown.x, y - recDown.y
    local d = math.sqrt(dx * dx + dy * dy)
    if d > recMax then recMax = d end
  elseif action == 1 and recDown then
    stick.x = recDown.x / sw
    stick.y = recDown.y / sh
    if recMax > 20 then stick.r = recMax / sw end
    recording = false
    recDown = nil
    saveCfg()
    notify(('[AutoPilot] джойстик записан: %.0f %.0f, радиус %.0f')
           :format(stick.x * sw, stick.y * sh, stick.r * sw), 5)
  end
  return true           -- игре тоже отдаём: пусть персонаж честно идёт
end

function onImgui()
  local s = getUiScale()
  if s and s > 0 then MDS = s end
  local w, h = getScreenSize()
  if w and w > 0 then sw, sh = w, h end

  drawStickHint()

  if active then
    imgui.DrawText(12 * MDS, sh - 34 * MDS, 'АВТОПИЛОТ: ' .. status,
                   0.25, 0.95, 0.45, 1)
  end

  if not menuOpen then return end

  imgui.SetNextWindowSize(420 * MDS, 0, imgui.Cond_Always)
  local visible, open = imgui.Begin('Автопилот', menuOpen,
    imgui.WindowFlags_NoResize + imgui.WindowFlags_AlwaysAutoResize)
  menuOpen = open

  if visible then
    if active then
      imgui.TextColored(status, 0.25, 0.95, 0.45, 1)
      if imgui.Button('Стоп', 400 * MDS, 34 * MDS) then stop('остановлено') end
    else
      imgui.TextDisabled(status)
    end

    imgui.Separator()
    imgui.Text('Куда идти')

    local list = waypoints()
    if #list == 0 then
      imgui.TextWrapped('Точек нет. Встаньте где надо и наберите ' ..
                        '/wp save имя — автопилот берёт их оттуда же.')
    else
      local me = ag.localPlayer()
      local x, y, z = me and ag.position(me)
      if imgui.BeginChild('##wps', 400 * MDS, 150 * MDS, true) then
        for _, t in ipairs(list) do
          local label = t.name
          if x then
            label = ('%s  —  %.0f м')
                    :format(t.name, getDistanceBetweenCoords3d(x, y, z,
                                                               t.x, t.y, t.z))
          end
          if imgui.Button(label .. '##go' .. t.name, 380 * MDS, 26 * MDS) then
            goTo(t)
          end
        end
      end
      imgui.EndChild()
    end

    imgui.Separator()
    imgui.Text('Джойстик')
    imgui.TextWrapped('Скрипт нажимает джойстик сам, поэтому ему надо ' ..
                      'знать, где он. Нажмите кнопку и один раз проведите ' ..
                      'пальцем как обычно.')
    if imgui.Button(recording and 'ведите пальцем…' or 'Записать джойстик',
                    400 * MDS, 34 * MDS) then
      recording = true
      notify('[AutoPilot] проведите пальцем по джойстику', 5)
    end

    imgui.SetNextItemWidth(200 * MDS)
    local ch, v = imgui.SliderInt('X', math.floor(stick.x * 100), 2, 98,
                                  ('%d%%'):format(stick.x * 100))
    if ch then stick.x = v / 100; saveCfg() end
    imgui.SetNextItemWidth(200 * MDS)
    ch, v = imgui.SliderInt('Y', math.floor(stick.y * 100), 2, 98,
                            ('%d%%'):format(stick.y * 100))
    if ch then stick.y = v / 100; saveCfg() end
    imgui.SetNextItemWidth(200 * MDS)
    ch, v = imgui.SliderInt('Радиус', math.floor(stick.r * 100), 1, 30,
                            ('%d%%'):format(stick.r * 100))
    if ch then stick.r = v / 100; saveCfg() end

    if imgui.Button('Проверка: вперёд две секунды', 400 * MDS, 34 * MDS) then
      lua_thread.create(function()
        local until_ = os.clock() + 2
        while os.clock() < until_ do
          push(0, -1)
          wait(30)
        end
        release()
        notify('[AutoPilot] если персонаж пошёл — джойстик найден верно', 5)
      end)
    end

    imgui.Separator()
    local cam = ag.rwCamera()
    if cam then
      imgui.TextDisabled(('камера движка 0x%X, поле зрения %.0f°')
                         :format(cam, ag.fov() or 0))
    else
      imgui.TextColored('камера движка не читается — идти вслепую нельзя',
                        1.0, 0.45, 0.3, 1)
    end
  end
  imgui.End()
end

-- ═════════════════════════════════════════════════════════════════ main

function main()
  loadCfg()

  registerChatCommand('ap', function() menuOpen = not menuOpen end)
  registerChatCommand('apstop', function() stop('остановлено') end)

  registerChatCommand('apgo', function(arg)
    arg = tostring(arg or ''):match('^%s*(.-)%s*$')
    local x, y = arg:match('^(-?[%d%.]+)%s+(-?[%d%.]+)$')
    if x then
      local me = ag.localPlayer()
      local _, _, mz = me and ag.position(me)
      goTo({ x = tonumber(x), y = tonumber(y), z = mz or 0, name = 'точке' })
      return
    end
    for _, t in ipairs(waypoints()) do
      if t.name == arg then goTo(t); return end
    end
    notify('[AutoPilot] нет такой точки: ' .. arg, 4)
  end)

  log('[AutoPilot] /ap — меню, /apgo <точка|x y>, /apstop')

  -- Шаг автопилота отдельной корутиной: тридцать раз в секунду хватает,
  -- чтобы держать курс, и не грузит кадр.
  while true do
    if active then
      local ok, err = pcall(step)
      if not ok then
        active = false
        release()
        log('[AutoPilot] сбой: ' .. tostring(err))
      end
    end
    wait(33)
  end
end

function onScriptTerminate()
  release()
  saveCfg()
end
