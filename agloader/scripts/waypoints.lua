-- Точки на карте без всякого окна: сохранил координаты, потом смотришь,
-- куда и сколько идти.
--
--   /wp save дом        запомнить, где стою
--   /wp list            все точки с расстоянием
--   /wp go дом          куда идти: расстояние и направление
--   /wp del дом         убрать
--   /wp here            просто показать, где я
--
-- Направление считается от того, куда смотрит камера, поэтому «вперёд»
-- значит именно вперёд по экрану. Если камера не найдена, направление
-- показывается по сторонам света.

script_name('Waypoints')
script_author('AGLoader')
script_version('1.0')

local ag = require 'arizona'

local points = {}
local cfgPath = getPaths().config .. '/waypoints.ini'

-- ═══════════════════════════════════════════════════════════════ конфиг

local function saveCfg()
  local f = io.open(cfgPath, 'w')
  if not f then return end
  local names = {}
  for name in pairs(points) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local p = points[name]
    f:write(('%s=%.2f %.2f %.2f\n'):format(name, p.x, p.y, p.z))
  end
  f:close()
end

local function loadCfg()
  local f = io.open(cfgPath, 'r')
  if not f then return end
  for line in f:lines() do
    local k, v = line:match('^([^=]+)=(.*)$')
    if k and v then
      local x, y, z = v:match('^(-?[%d%.]+) (-?[%d%.]+) (-?[%d%.]+)$')
      if x then
        points[k] = { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
      end
    end
  end
  f:close()
end

-- ═══════════════════════════════════════════════════════════ где я

local function myPos()
  local me = ag.localPlayer()
  if not me then return nil, 'игрок не найден — вы ещё не в мире' end
  local x, y, z = ag.position(me)
  if not x then return nil, 'позиция не читается' end
  return x, y, z
end

-- Стороны света по вектору. В San Andreas ось Y смотрит на север.
local COMPASS = { 'север', 'северо-восток', 'восток', 'юго-восток',
                  'юг', 'юго-запад', 'запад', 'северо-запад' }

local function compass(dx, dy)
  local ang = math.deg(math.atan2(dx, dy)) % 360
  local i = math.floor((ang + 22.5) / 45) % 8 + 1
  return COMPASS[i]
end

-- Направление относительно камеры: «вперёд», «направо» и так далее.
local function relative(dx, dy)
  local cam = ag.cameraMatrix()
  if not cam then return nil end
  local o = (ag.cam.fwdAxis - 1) * 4
  local fx = cam[o + 1] * ag.cam.fwdSign
  local fy = cam[o + 2] * ag.cam.fwdSign

  local len = math.sqrt(fx * fx + fy * fy)
  if len < 0.001 then return nil end
  fx, fy = fx / len, fy / len

  local dlen = math.sqrt(dx * dx + dy * dy)
  if dlen < 0.001 then return 'здесь' end
  local nx, ny = dx / dlen, dy / dlen

  -- Знак векторного произведения на плоскости говорит, слева цель или
  -- справа, а скалярное — впереди или позади.
  local dot = fx * nx + fy * ny
  local cross = fx * ny - fy * nx

  if dot > 0.85 then return 'прямо вперёд' end
  if dot < -0.85 then return 'позади' end
  if dot > 0 then
    return cross > 0 and 'вперёд-налево' or 'вперёд-направо'
  end
  return cross > 0 and 'назад-налево' or 'назад-направо'
end

local function describe(name, p, x, y, z)
  local d = getDistanceBetweenCoords3d(x, y, z, p.x, p.y, p.z)
  local dx, dy = p.x - x, p.y - y
  local rel = relative(dx, dy)
  return ('%s — %.0f м, %s%s'):format(
    name, d, compass(dx, dy),
    rel and (' (' .. rel .. ')') or '')
end

-- ═══════════════════════════════════════════════════════════ команды

local function cmdSave(name)
  if name == '' then log('[Waypoints] /wp save <имя>'); return end
  local x, y, z = myPos()
  if not x then log('[Waypoints] ' .. y); return end
  points[name] = { x = x, y = y, z = z }
  saveCfg()
  log(('[Waypoints] «%s» = %.1f %.1f %.1f'):format(name, x, y, z))
end

local function cmdDel(name)
  if not points[name] then log('[Waypoints] такой точки нет'); return end
  points[name] = nil
  saveCfg()
  log('[Waypoints] убрана «' .. name .. '»')
end

local function cmdList()
  local x, y, z = myPos()
  local names = {}
  for name in pairs(points) do names[#names + 1] = name end
  if #names == 0 then
    log('[Waypoints] точек нет. Встаньте где надо и наберите /wp save имя')
    return
  end

  if x then
    table.sort(names, function(a, b)
      local pa, pb = points[a], points[b]
      return getDistanceBetweenCoords3d(x, y, z, pa.x, pa.y, pa.z)
           < getDistanceBetweenCoords3d(x, y, z, pb.x, pb.y, pb.z)
    end)
  else
    table.sort(names)
  end

  log(('[Waypoints] точек: %d'):format(#names))
  for _, name in ipairs(names) do
    local p = points[name]
    if x then
      log('  ' .. describe(name, p, x, y, z))
    else
      log(('  %s — %.1f %.1f %.1f'):format(name, p.x, p.y, p.z))
    end
  end
end

local function cmdGo(name)
  local p = points[name]
  if not p then log('[Waypoints] такой точки нет'); return end
  local x, y, z = myPos()
  if not x then log('[Waypoints] ' .. y); return end
  log('[Waypoints] ' .. describe(name, p, x, y, z))
end

local function cmdHere()
  local x, y, z = myPos()
  if not x then log('[Waypoints] ' .. y); return end
  local me = ag.localPlayer()
  log(('[Waypoints] %.1f %.1f %.1f, %s, %.0f км/ч'):format(
      x, y, z, ag.inVehicle(me) and 'за рулём' or 'пешком',
      ag.speedKmh(me) or 0))
end

-- ═════════════════════════════════════════════════════════════════ main

function main()
  loadCfg()

  registerChatCommand('wp', function(arg)
    local what, rest = tostring(arg or ''):match('^(%S*)%s*(.*)$')
    rest = rest:match('^%s*(.-)%s*$')
    if     what == 'save' then cmdSave(rest)
    elseif what == 'del'  then cmdDel(rest)
    elseif what == 'list' or what == '' then cmdList()
    elseif what == 'go'   then cmdGo(rest)
    elseif what == 'here' then cmdHere()
    else
      log('[Waypoints] /wp save|del|go <имя>, /wp list, /wp here')
    end
  end)

  log(('[Waypoints] /wp list — точек сохранено: %d')
      :format((function()
        local n = 0
        for _ in pairs(points) do n = n + 1 end
        return n
      end)()))
end
