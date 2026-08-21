-- Спидометр и координаты — самый короткий способ убедиться, что чтение
-- памяти движка работает.
--
--   /speed        показать или убрать панель
--   /speedpos     переставить панель в другой угол
--
-- Всё, что здесь показано, читается прямо из libag-client.so: указатель на
-- игрока, его координаты и вектор скорости. Ничего от SA-MP тут нет.

script_name('Speedometer')
script_author('AGLoader')
script_version('1.0')

local ag = require 'arizona'

local shown  = true
local corner = 1              -- 1 левый верх, 2 правый верх, 3 правый низ, 4 левый низ
local MDS, sw, sh = 1, 1280, 720

-- Пройденный путь и максимальная скорость за сессию — считаются в main().
local travelled, topSpeed = 0, 0
local lastX, lastY, lastZ

local cfgPath = getPaths().config .. '/speedometer.ini'

local function saveCfg()
  local f = io.open(cfgPath, 'w')
  if not f then return end
  f:write(('corner=%d\nshown=%s\n'):format(corner, tostring(shown)))
  f:close()
end

local function loadCfg()
  local f = io.open(cfgPath, 'r')
  if not f then return end
  for line in f:lines() do
    local k, v = line:match('^(%w+)=(.*)$')
    if k == 'corner' then corner = tonumber(v) or corner
    elseif k == 'shown' then shown = (v == 'true') end
  end
  f:close()
end

-- ═══════════════════════════════════════════════════════════ отрисовка

local W, H = 210, 96

local function panelPos()
  local m = 16 * MDS
  local w, h = W * MDS, H * MDS
  if corner == 1 then return m, m end
  if corner == 2 then return sw - w - m, m end
  if corner == 3 then return sw - w - m, sh - h - m end
  return m, sh - h - m
end

function onImgui()
  local s = getUiScale()
  if s and s > 0 then MDS = s end
  local w, h = getScreenSize()
  if w and w > 0 then sw, sh = w, h end

  if not shown then return end

  local me = ag.localPlayer()
  local x, y, z = 0, 0, 0
  local kmh, inVeh = 0, false
  if me then
    local px, py, pz = ag.position(me)
    if px then x, y, z = px, py, pz end
    kmh = ag.speedKmh(me) or 0
    inVeh = ag.inVehicle(me)
  end

  local px, py = panelPos()
  local pw, ph = W * MDS, H * MDS

  imgui.DrawRectFilled(px, py, px + pw, py + ph, 0.05, 0.06, 0.09, 0.82)
  imgui.DrawRectFilled(px, py, px + pw, py + 3 * MDS, 0.80, 0.10, 0.10, 1.0)

  local lx = px + 10 * MDS
  local ly = py + 10 * MDS
  local step = 17 * MDS

  if not me then
    imgui.DrawText(lx, ly, 'игрок не найден', 1.0, 0.45, 0.30, 1)
    return
  end

  -- Скорость крупно и цветом по величине: спокойный, обычный, быстрый.
  local r, g, b = 0.30, 0.90, 0.45
  if kmh > 120 then r, g, b = 1.00, 0.35, 0.30
  elseif kmh > 60 then r, g, b = 1.00, 0.85, 0.20 end

  imgui.DrawText(lx, ly, ('%.0f км/ч'):format(kmh), r, g, b, 1)
  imgui.DrawText(lx + 96 * MDS, ly,
                 inVeh and 'за рулём' or 'пешком', 0.60, 0.62, 0.70, 1)

  ly = ly + step
  imgui.DrawText(lx, ly, ('X %.1f  Y %.1f  Z %.1f'):format(x, y, z),
                 0.85, 0.86, 0.90, 1)
  ly = ly + step
  imgui.DrawText(lx, ly, ('путь %.2f км   максимум %.0f км/ч')
                 :format(travelled / 1000, topSpeed), 0.60, 0.62, 0.70, 1)
  ly = ly + step
  imgui.DrawText(lx, ly, ('слот %d   кадр %.1f мс')
                 :format(ag.localIndex() or -1, getFrameTime() * 1000),
                 0.45, 0.47, 0.55, 1)
end

-- ═════════════════════════════════════════════════════════════════ main

function main()
  loadCfg()

  registerChatCommand('speed', function()
    shown = not shown
    saveCfg()
    log('[Speedometer] панель ' .. (shown and 'включена' or 'выключена'))
  end)

  registerChatCommand('speedpos', function()
    corner = corner % 4 + 1
    saveCfg()
    log('[Speedometer] угол ' .. corner)
  end)

  log('[Speedometer] /speed — панель, /speedpos — угол')

  while true do
    wait(200)
    local me = ag.localPlayer()
    if me then
      local x, y, z = ag.position(me)
      if x then
        if lastX then
          local d = getDistanceBetweenCoords3d(x, y, z, lastX, lastY, lastZ)
          -- Скачок больше сотни метров за 200 мс — это телепорт, не путь.
          if d < 100 then travelled = travelled + d end
        end
        lastX, lastY, lastZ = x, y, z
      end
      local kmh = ag.speedKmh(me) or 0
      if kmh > topSpeed and kmh < 1000 then topSpeed = kmh end
    end
  end
end
