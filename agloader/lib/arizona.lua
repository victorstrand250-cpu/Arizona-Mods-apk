-- Доступ к данным нового движка Arizona.
--
--   local ag = require 'arizona'
--   local me = ag.localPlayer()
--   if me then
--     local x, y, z = ag.position(me)
--     print(('я тут: %.1f %.1f %.1f, скорость %.0f км/ч'):format(x, y, z,
--           ag.speedKmh(me)))
--   end
--
--   for _, p in ipairs(ag.players()) do
--     print(p.index, p.x, p.y, p.z, p.inVehicle)
--   end
--
-- Откуда взялись смещения. Движок собран без символов, но наружу торчит
-- JNI-метод GTASA.getLocalVehicleSpeed — маленькая функция, которой всё
-- равно приходится дойти до игрока. Её разбор дал всю цепочку:
--
--   индекс = *(uint16*)(база + 0x1589F50)
--   игрок  = *(void**)(база + 0x150E950 + индекс * 336)
--   если игрок в транспорте, дальше работают с указателем игрок->[1112]
--
-- Смещения полей подтверждены разбором 407 мест, где движок обращается к
-- этому массиву, и вот такой последовательностью — это функция «дай
-- координаты игрока»:
--
--   ldr  x10, [x9, #1112]   ; транспорт
--   ldrb w11, [x9, #1120]   ; флаг «в транспорте»
--   csel x9,  x10, x9, ne   ; берём транспорт, иначе пешехода
--   ldr  d1,  [x9, #56]     ; x и y одной парой
--   ldr  s0,  [x9, #64]     ; z

local arizona = {}

-- ═════════════════════════════════════════════════════════════ смещения

-- От базы libag-client.so.
arizona.OFF_PLAYER_ARRAY = 0x150E950   -- массив слотов
arizona.OFF_LOCAL_INDEX  = 0x1589F50   -- uint16, индекс своего слота
arizona.SLOT_STRIDE      = 336         -- размер слота, указатель в начале
arizona.NO_PLAYER        = 0xFFFF      -- «слота нет»

-- Внутри объекта сущности. Пешеход и транспорт делят общую базу: движок
-- читает позицию по одним и тем же смещениям, что видно по csel выше.
arizona.OFF_POS      = 56     -- x, y, z подряд
arizona.OFF_VELOCITY = 260    -- x, y, z подряд
arizona.OFF_VEHICLE  = 1112   -- указатель на транспорт
arizona.OFF_IN_VEH   = 1120   -- байт: игрок внутри транспорта

-- Множитель из самого движка: |скорость| * 175 = км/ч.
arizona.SPEED_TO_KMH = 175.0

-- Сколько слотов перебирать. Точный предел из кода вытащить не удалось,
-- поэтому берём с запасом и проверяем каждый слот на осмысленность.
arizona.MAX_SLOTS = 1024

-- ═════════════════════════════════════════════════════════ пул сущностей

-- Второй крупный массив движка: указатели на сущности мира, шаг 8 байт.
-- Найден по коду, где рядом стоит предел индекса и проверка типа:
--
--   mov  w8, #0x765c          ; предел 30300
--   cmp  w20, w8
--   adrp x8, 0x3110000
--   add  x8, x8, #0x540
--   ldr  x22, [x8, x20, lsl #3]
--   ldrb w8, [x22, #29]       ; тип
--   mov  w9, #0x4e0           ; маска допустимых типов
--   tst  w8, w9
--
-- Маска 0x4E0 пропускает типы 5, 6, 7, 8 и 10.
arizona.OFF_POOL   = 0x3110540
arizona.POOL_MAX   = 30300
arizona.OFF_TYPE   = 29     -- uint8, тип сущности
arizona.OFF_MODEL  = 44     -- uint16, номер модели
arizona.OFF_INNER  = 32     -- указатель на описание модели с габаритами

-- Смещение позиции внутри объекта пула по коду вычислить не удалось:
-- отрисовка берёт её через матрицу, а не полем. Зато его можно определить
-- на живой игре — см. findPoolPositionOffset ниже.
arizona.poolPosOffset = nil

-- ═══════════════════════════════════════════════════════════════ основа

local base = 0

-- База библиотеки меняется при каждом запуске, поэтому берём её заново,
-- пока не получится.
local function getBase()
  if base == 0 then
    base = memory.getclientbase() or 0
  end
  return base
end

function arizona.available()
  return getBase() ~= 0
end

-- Похож ли адрес на живой объект в куче.
local function sanePointer(p)
  return p and p > 0x10000 and p < 0x1000000000000
end

-- Координаты в разумных мировых пределах и не NaN.
local function saneCoord(v)
  return v and v == v and v > -30000 and v < 30000
end

function arizona.localIndex()
  local b = getBase()
  if b == 0 then return nil end
  local idx = memory.readu16(b + arizona.OFF_LOCAL_INDEX)
  if not idx or idx == arizona.NO_PLAYER then return nil end
  return idx
end

-- Указатель на объект игрока по номеру слота.
function arizona.playerPtr(index)
  local b = getBase()
  if b == 0 or not index then return nil end
  local p = memory.deref(b + arizona.OFF_PLAYER_ARRAY
                           + index * arizona.SLOT_STRIDE)
  if not sanePointer(p) then return nil end
  return p
end

function arizona.localPlayer()
  return arizona.playerPtr(arizona.localIndex())
end

-- ═══════════════════════════════════════════════════════ работа с пулом

function arizona.poolPtr(index)
  local b = getBase()
  if b == 0 or not index then return nil end
  local p = memory.deref(b + arizona.OFF_POOL + index * 8)
  if not sanePointer(p) then return nil end
  return p
end

function arizona.poolType(ptr)
  return ptr and memory.readu8(ptr + arizona.OFF_TYPE) or nil
end

function arizona.poolModel(ptr)
  return ptr and memory.readu16(ptr + arizona.OFF_MODEL) or nil
end

function arizona.poolPosition(ptr)
  local off = arizona.poolPosOffset
  if not ptr or not off then return nil end
  local x = memory.readfloat(ptr + off)
  local y = memory.readfloat(ptr + off + 4)
  local z = memory.readfloat(ptr + off + 8)
  if not saneCoord(x) or not saneCoord(y) or not saneCoord(z) then
    return nil
  end
  return x, y, z
end

-- Занятые места пула.
--
-- opts: { limit = 30300, max = 2000, near = {x,y,z}, radius = 300 }
function arizona.poolObjects(opts)
  opts = opts or {}
  local limit = math.min(opts.limit or arizona.POOL_MAX, arizona.POOL_MAX)
  local max = opts.max or 2000
  local near, radius = opts.near, opts.radius or 300

  if getBase() == 0 then return {} end

  local out = {}
  for i = 0, limit - 1 do
    local ptr = arizona.poolPtr(i)
    if ptr then
      local rec = { index = i, ptr = ptr,
                    type = arizona.poolType(ptr),
                    model = arizona.poolModel(ptr) }
      if arizona.poolPosOffset then
        local x, y, z = arizona.poolPosition(ptr)
        if x then
          rec.x, rec.y, rec.z = x, y, z
          if near then
            local dx, dy, dz = x - near[1], y - near[2], z - near[3]
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d > radius then rec = nil else rec.dist = d end
          end
        elseif near then
          rec = nil
        end
      end
      if rec then
        out[#out + 1] = rec
        if #out >= max then break end
      end
    end
  end
  return out
end

-- Определяет смещение позиции опытным путём. Объекты пула стримятся вокруг
-- игрока, поэтому верное смещение — то, где у большинства объектов лежат
-- три числа, похожие на координаты неподалёку.
function arizona.findPoolPositionOffset(px, py, pz, opts)
  opts = opts or {}
  local sample = opts.sample or 300
  local maxOff = opts.maxOff or 512
  local radius = opts.radius or 600

  local objs = {}
  for i = 0, arizona.POOL_MAX - 1 do
    local p = arizona.poolPtr(i)
    if p then
      objs[#objs + 1] = p
      if #objs >= sample then break end
    end
  end
  if #objs < 8 then return nil, 0, #objs end

  local best, bestHits = nil, 0
  for off = 0, maxOff - 12, 4 do
    local hits = 0
    for _, p in ipairs(objs) do
      local x = memory.readfloat(p + off)
      if x and x == x and x > -30000 and x < 30000 then
        local y = memory.readfloat(p + off + 4)
        local z = memory.readfloat(p + off + 8)
        if y and z and y == y and z == z then
          local dx, dy, dz = x - px, y - py, z - pz
          local d = math.sqrt(dx * dx + dy * dy + dz * dz)
          -- Ровный ноль встречается в памяти слишком часто, чтобы верить.
          if d < radius and not (x == 0 and y == 0 and z == 0) then
            hits = hits + 1
          end
        end
      end
    end
    if hits > bestHits then best, bestHits = off, hits end
  end

  -- Меньше четверти выборки — это совпадение, а не находка.
  if bestHits < #objs / 4 then return nil, bestHits, #objs end
  arizona.poolPosOffset = best
  return best, bestHits, #objs
end

-- ═══════════════════════════════════════════════════════════ свойства

function arizona.inVehicle(ptr)
  if not ptr then return false end
  local veh = memory.deref(ptr + arizona.OFF_VEHICLE)
  local flag = memory.readu8(ptr + arizona.OFF_IN_VEH)
  return sanePointer(veh) and flag ~= nil and flag ~= 0
end

function arizona.vehiclePtr(ptr)
  if not ptr then return nil end
  local veh = memory.deref(ptr + arizona.OFF_VEHICLE)
  return sanePointer(veh) and veh or nil
end

-- Тот объект, чью позицию имеет смысл спрашивать: в транспорте это сам
-- транспорт, иначе пешеход. Ровно так делает движок.
function arizona.entity(ptr)
  if not ptr then return nil end
  if arizona.inVehicle(ptr) then
    return arizona.vehiclePtr(ptr) or ptr
  end
  return ptr
end

function arizona.position(ptr)
  local e = arizona.entity(ptr)
  if not e then return nil end
  local x = memory.readfloat(e + arizona.OFF_POS)
  local y = memory.readfloat(e + arizona.OFF_POS + 4)
  local z = memory.readfloat(e + arizona.OFF_POS + 8)
  if not saneCoord(x) or not saneCoord(y) or not saneCoord(z) then
    return nil
  end
  return x, y, z
end

function arizona.velocity(ptr)
  local e = arizona.entity(ptr)
  if not e then return nil end
  local x = memory.readfloat(e + arizona.OFF_VELOCITY)
  local y = memory.readfloat(e + arizona.OFF_VELOCITY + 4)
  local z = memory.readfloat(e + arizona.OFF_VELOCITY + 8)
  if not x or x ~= x then return nil end
  return x, y, z
end

function arizona.speedKmh(ptr)
  local vx, vy, vz = arizona.velocity(ptr)
  if not vx then return 0 end
  return math.sqrt(vx * vx + vy * vy + vz * vz) * arizona.SPEED_TO_KMH
end

-- ══════════════════════════════════════════════════════════ перебор

-- Все занятые слоты. Возвращает список записей с уже прочитанной позицией,
-- чтобы не ходить в память по второму разу.
--
-- opts: { limit = 1024, withPos = true, skipLocal = false }
function arizona.players(opts)
  opts = opts or {}
  local limit = opts.limit or arizona.MAX_SLOTS
  local withPos = opts.withPos ~= false
  local b = getBase()
  if b == 0 then return {} end

  local me = arizona.localIndex()
  local out = {}

  for i = 0, limit - 1 do
    if not (opts.skipLocal and i == me) then
      local ptr = arizona.playerPtr(i)
      if ptr then
        local rec = { index = i, ptr = ptr, isLocal = (i == me) }
        if withPos then
          local x, y, z = arizona.position(ptr)
          if x then
            rec.x, rec.y, rec.z = x, y, z
            rec.inVehicle = arizona.inVehicle(ptr)
            out[#out + 1] = rec
          end
        else
          out[#out + 1] = rec
        end
      end
    end
  end
  return out
end

function arizona.distanceTo(ptr, x, y, z)
  local px, py, pz = arizona.position(ptr)
  if not px then return nil end
  local dx, dy, dz = px - x, py - y, pz - z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ══════════════════════════════════════════════════ камера и проекция
--
-- Матрицу камеры в коде найти не удалось: движок пишет вызовы GL в командный
-- буфер, и указатель на матрицы в аргументах — копия внутри буфера. Зато на
-- живой игре камера опознаётся однозначно: это единственная матрица
-- положения, которая стоит в нескольких метрах от игрока и смотрит прямо
-- на него. Позиция игрока известна статически, так что проверка точная.

arizona.cam = {
  addr    = 0,
  fov     = 70,
  fwdAxis = 2,
  upAxis  = 3,
  fwdSign = 1,
  mirrorX = false,
  mirrorY = false,
}

local function matRow(m, i)
  local o = (i - 1) * 4
  return m[o + 1], m[o + 2], m[o + 3]
end

local function dot3(ax, ay, az, bx, by, bz)
  return ax * bx + ay * by + az * bz
end

-- Ищет камеру среди матриц памяти. candidates — уже готовый список от
-- memory.findmatrix; если не передан, сканирование делается здесь.
-- Возвращает адрес и точность попадания, либо nil.
function arizona.findCamera(candidates)
  local me = arizona.localPlayer()
  if not me then return nil, 'игрок не найден' end
  local px, py, pz = arizona.position(me)
  if not px then return nil, 'позиция игрока не читается' end

  local list = candidates
  if not list then
    local found, count = memory.findmatrix({ tol = 0.01, limit = 20000 })
    if not found then return nil, tostring(count) end
    list = found
  end

  local best, bestDot, bestAxis, bestSign, bestDist = 0, 0.90, 0, 1, 0
  for _, addr in ipairs(list) do
    local m = memory.readmatrix(addr)
    if m then
      local cx, cy, cz = m[13], m[14], m[15]
      local dx, dy, dz = px - cx, py - cy, pz - cz
      local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
      -- Слишком близко — это сам игрок, слишком далеко — не наша камера.
      if dist > 0.7 and dist < 40 then
        local tx, ty, tz = dx / dist, dy / dist, dz / dist
        for axis = 1, 3 do
          local ax, ay, az = matRow(m, axis)
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

  if best == 0 then return nil, 'камера не опознана' end

  arizona.cam.addr = best
  arizona.cam.fwdAxis = bestAxis
  arizona.cam.fwdSign = bestSign

  -- «Вверх» — из двух оставшихся осей та, что ближе к мировой вертикали.
  local cm = memory.readmatrix(best)
  local bestUp, bestUpZ = 0, -2
  for axis = 1, 3 do
    if axis ~= bestAxis then
      local _, _, az = matRow(cm, axis)
      if az > bestUpZ then bestUp, bestUpZ = axis, az end
    end
  end
  arizona.cam.upAxis = bestUp

  return best, bestDot, bestDist
end

function arizona.cameraMatrix()
  if arizona.cam.addr == 0 then return nil end
  return memory.readmatrix(arizona.cam.addr)
end

-- Мировые координаты в экранные. Возвращает x, y и расстояние до камеры,
-- либо nil, если точка за спиной.
function arizona.worldToScreen(wx, wy, wz, sw, sh, cam)
  cam = cam or arizona.cameraMatrix()
  if not cam then return nil end
  if not sw then sw, sh = getScreenSize() end
  if not sw or sw == 0 then return nil end

  local c = arizona.cam
  local dx, dy, dz = wx - cam[13], wy - cam[14], wz - cam[15]

  local fx, fy, fz = matRow(cam, c.fwdAxis)
  fx, fy, fz = fx * c.fwdSign, fy * c.fwdSign, fz * c.fwdSign
  local ux, uy, uz = matRow(cam, c.upAxis)

  -- Правая ось через векторное произведение — так она согласована
  -- с выбранными «вперёд» и «вверх» при любом их сочетании.
  local rx = fy * uz - fz * uy
  local ry = fz * ux - fx * uz
  local rz = fx * uy - fy * ux

  local depth = dot3(dx, dy, dz, fx, fy, fz)
  if depth <= 0.05 then return nil end

  local hx = dot3(dx, dy, dz, rx, ry, rz)
  local hy = dot3(dx, dy, dz, ux, uy, uz)

  local tanHalf = math.tan(math.rad(c.fov) / 2)
  local nx = hx / (depth * tanHalf * (sw / sh))
  local ny = hy / (depth * tanHalf)
  if c.mirrorX then nx = -nx end
  if c.mirrorY then ny = -ny end

  return sw / 2 + nx * (sw / 2), sh / 2 - ny * (sh / 2), depth
end

-- Настройки проекции лежат в общем файле: их подбирает разведка, а
-- пользуются все скрипты.
arizona.PROJECTION_FILE = 'recon.ini'

function arizona.saveProjection(path)
  path = path or (getPaths().config .. '/' .. arizona.PROJECTION_FILE)
  local f = io.open(path, 'w')
  if not f then return false end
  local c = arizona.cam
  f:write(('fov=%d\nfwdAxis=%d\nupAxis=%d\nfwdSign=%d\nmirrorX=%s\nmirrorY=%s\n')
          :format(c.fov, c.fwdAxis, c.upAxis, c.fwdSign,
                  tostring(c.mirrorX), tostring(c.mirrorY)))
  if arizona.poolPosOffset then
    f:write(('poolPos=%d\n'):format(arizona.poolPosOffset))
  end
  f:close()
  return true
end

function arizona.loadProjection(path)
  path = path or (getPaths().config .. '/' .. arizona.PROJECTION_FILE)
  local f = io.open(path, 'r')
  if not f then return false end
  local c = arizona.cam
  for line in f:lines() do
    local k, v = line:match('^(%w+)=(.*)$')
    if     k == 'fov'     then c.fov = tonumber(v) or c.fov
    elseif k == 'fwdAxis' then c.fwdAxis = tonumber(v) or c.fwdAxis
    elseif k == 'upAxis'  then c.upAxis = tonumber(v) or c.upAxis
    elseif k == 'fwdSign' then c.fwdSign = tonumber(v) or c.fwdSign
    elseif k == 'mirrorX' then c.mirrorX = (v == 'true')
    elseif k == 'mirrorY' then c.mirrorY = (v == 'true')
    elseif k == 'poolPos' then arizona.poolPosOffset = tonumber(v)
    end
  end
  f:close()
  return true
end

return arizona
