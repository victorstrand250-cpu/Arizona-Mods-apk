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

return arizona
