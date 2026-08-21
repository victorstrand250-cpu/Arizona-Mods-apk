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

-- ══════════════════════════════════════════════════════ сущности мира

-- Пулы сущностей движок держит не в .bss, а в куче: в библиотеке лежит
-- только указатель на массив. В коде это выглядит так (0x56DBA0):
--
--   adrp x8, 0x315a000
--   ldr  x8, [x8, #3608]        ; сам массив
--   ldrh w9, [x22, #172]        ; номер места
--   cmp  w9, #0x7cf             ; предел, 2000 мест
--   ldr  x10, [x8, x9, lsl #3]  ; сущность
--   ldr  d0, [x10, #56]         ; позиция x и y
--   ldr  s1, [x10, #64]         ; позиция z
--
-- Сразу за массивом указателей идёт карта занятости — по байту на место
-- (0x699C20: strb wzr, [массив + 8000 + номер]).
arizona.POOLS = {
  { name = 'сущности', global = 0x315AE18, count = 2000 },
  { name = 'объекты',  global = 0x315AE28, count = 1000 },
  { name = 'пешеходы', global = 0x3159650, count = 1000 },
}

-- Поля сущности. Позиция и скорость те же, что у игрока: пешеход,
-- транспорт и объект мира происходят от одного класса.
arizona.OFF_ENT_MODEL = 108   -- int16, номер модели (230 обращений в коде)
arizona.OFF_ENT_STATE = 980   -- int32, состояние; 49 — за рулём

-- Массив описаний моделей: 30300 мест по указателю. Раньше он принимался
-- за пул сущностей — отсюда и пустой ESP. Отличается однозначно: сущность
-- читают по +56 (позиция), описание модели — по +29 и +44, а по +56 не
-- читают никогда.
--
--   mov  w8, #0x765c          ; предел 30300
--   ldr  x22, [x8, x20, lsl #3]
--   ldrb w8, [x22, #29]       ; тип
--   mov  w9, #0x4e0           ; маска допустимых типов
--
-- Индекс сюда берут прямо из сущности: ldrsh w, [сущность, #108].
arizona.OFF_MODEL_INFO  = 0x3110540
arizona.MODEL_INFO_MAX  = 30300
arizona.OFF_MI_TYPE     = 29    -- uint8, тип модели
arizona.OFF_MI_INDEX    = 44    -- uint16, номер модели
arizona.OFF_MI_INNER    = 32    -- указатель на геометрию

-- Старые имена: ими пользовались скрипты, пока пул считался сущностным.
arizona.OFF_POOL  = arizona.OFF_MODEL_INFO
arizona.POOL_MAX  = arizona.MODEL_INFO_MAX
arizona.OFF_TYPE  = arizona.OFF_MI_TYPE
arizona.OFF_MODEL = arizona.OFF_MI_INDEX
arizona.OFF_INNER = arizona.OFF_MI_INNER

-- Позиция сущности лежит там же, где у игрока. Значение перепроверяется на
-- живой игре — см. findPoolPositionOffset.
arizona.poolPosOffset = 56

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

-- Адрес массива сущностей для пула: в библиотеке лежит указатель, сам
-- массив выделен в куче и переезжает при каждом запуске.
function arizona.poolArray(n)
  local b = getBase()
  local p = arizona.POOLS[n]
  if b == 0 or not p then return nil end
  local addr = memory.deref(b + p.global)
  if not sanePointer(addr) then return nil end
  return addr, p.count, p.name
end

-- Карта занятости: по байту на место сразу за массивом указателей.
function arizona.poolUsed(n, index)
  local addr, count = arizona.poolArray(n)
  if not addr or index < 0 or index >= count then return false end
  local u = memory.readu8(addr + count * 8 + index)
  return u ~= nil and u ~= 0
end

-- Описание модели по её номеру.
function arizona.modelInfo(model)
  local b = getBase()
  if b == 0 or not model or model < 0 or model >= arizona.MODEL_INFO_MAX then
    return nil
  end
  local p = memory.deref(b + arizona.OFF_MODEL_INFO + model * 8)
  if not sanePointer(p) then return nil end
  return p, memory.readu8(p + arizona.OFF_MI_TYPE)
end

-- Место пула. Обратная совместимость: без номера пула берётся первый.
function arizona.poolPtr(index, n)
  local addr, count = arizona.poolArray(n or 1)
  if not addr or not index or index < 0 or index >= count then return nil end
  local p = memory.deref(addr + index * 8)
  if not sanePointer(p) then return nil end
  return p
end

function arizona.poolType(ptr)
  if not ptr then return nil end
  local model = memory.readi16(ptr + arizona.OFF_ENT_MODEL)
  if not model then return nil end
  local _, t = arizona.modelInfo(model)
  return t
end

function arizona.poolModel(ptr)
  return ptr and memory.readi16(ptr + arizona.OFF_ENT_MODEL) or nil
end

function arizona.poolPosition(ptr)
  local off = arizona.poolPosOffset or arizona.OFF_POS
  if not ptr then return nil end
  local x = memory.readfloat(ptr + off)
  local y = memory.readfloat(ptr + off + 4)
  local z = memory.readfloat(ptr + off + 8)
  if not saneCoord(x) or not saneCoord(y) or not saneCoord(z) then
    return nil
  end
  return x, y, z
end

-- Сущности мира из всех пулов сразу.
--
-- opts: { pools = {1,2,3}, near = {x,y,z}, radius = 300, max = 4000 }
--
-- Читается пакетно: массив указателей одним куском, затем каждое поле сразу
-- у всех сущностей. Поштучное чтение здесь неприменимо — на четыре тысячи
-- мест вышло бы больше десяти тысяч системных вызовов на одно обновление.
function arizona.entities(opts)
  opts = opts or {}
  local max = opts.max or 4000
  local near, radius = opts.near, opts.radius or 300
  local which = opts.pools

  if getBase() == 0 then return {} end

  local r2 = radius * radius
  local nx, ny, nz
  if near then nx, ny, nz = near[1], near[2], near[3] end

  local off = arizona.poolPosOffset or arizona.OFF_POS
  local out = {}

  for n = 1, #arizona.POOLS do
    local take = true
    if which then
      take = false
      for _, w in ipairs(which) do if w == n then take = true end end
    end

    local addr, count, name = arizona.poolArray(n)
    if take and addr then
      local ptrs, slots = memory.readptrs(addr, count)
      if ptrs and #ptrs > 0 then
        local pos, posOk = memory.gather(ptrs, off, 'f32x3')
        local models = memory.gather(ptrs, arizona.OFF_ENT_MODEL, 'i16')

        for i = 1, #ptrs do
          local x, y, z, d
          local keep = true
          if posOk[i] then
            local o = (i - 1) * 3
            x, y, z = pos[o + 1], pos[o + 2], pos[o + 3]
            if not (saneCoord(x) and saneCoord(y) and saneCoord(z)) then
              x, y, z = nil, nil, nil
            end
          end
          if near then
            if not x then
              keep = false
            else
              local dx, dy, dz = x - nx, y - ny, z - nz
              local q = dx * dx + dy * dy + dz * dz
              if q > r2 then keep = false else d = math.sqrt(q) end
            end
          end
          if keep then
            out[#out + 1] = {
              pool = n, poolName = name, index = slots[i], ptr = ptrs[i],
              model = models and models[i], x = x, y = y, z = z, dist = d,
            }
            if #out >= max then return out end
          end
        end
      end
    end
  end
  return out
end

-- Прежнее имя: скрипты звали пул объектов так.
function arizona.poolObjects(opts)
  return arizona.entities(opts)
end

-- Проверяет, что позиция сущности действительно лежит по known-смещению, и
-- при расхождении подбирает верное. Сущности стримятся вокруг игрока,
-- поэтому верное смещение — то, где у большинства лежат координаты
-- неподалёку.
--
-- Возвращает смещение, сколько сущностей его подтвердили и размер выборки.
function arizona.findPoolPositionOffset(px, py, pz, opts)
  opts = opts or {}
  local sample = opts.sample or 400
  local maxOff = opts.maxOff or 512
  local radius = opts.radius or 600

  local objs = {}
  for n = 1, #arizona.POOLS do
    local addr, count = arizona.poolArray(n)
    if addr then
      local ptrs = memory.readptrs(addr, count)
      for i = 1, #ptrs do
        objs[#objs + 1] = ptrs[i]
        if #objs >= sample then break end
      end
    end
    if #objs >= sample then break end
  end
  if #objs < 8 then return nil, 0, #objs end

  local function score(o)
    local pos, ok = memory.gather(objs, o, 'f32x3')
    if not pos then return 0 end
    local hits = 0
    for i = 1, #objs do
      if ok[i] then
        local k = (i - 1) * 3
        local x, y, z = pos[k + 1], pos[k + 2], pos[k + 3]
        -- Ровный ноль встречается в памяти слишком часто, чтобы верить.
        if saneCoord(x) and saneCoord(y) and saneCoord(z)
           and not (x == 0 and y == 0 and z == 0) then
          local dx, dy, dz = x - px, y - py, z - pz
          if dx * dx + dy * dy + dz * dz < radius * radius then
            hits = hits + 1
          end
        end
      end
    end
    return hits
  end

  local need = #objs / 4
  local known = arizona.OFF_POS
  local kh = score(known)
  if kh >= need then
    arizona.poolPosOffset = known
    return known, kh, #objs
  end

  local best, bestHits = nil, kh
  for o = 0, maxOff - 12, 4 do
    if o ~= known then
      local h = score(o)
      if h > bestHits then best, bestHits = o, h end
    end
  end

  if not best or bestHits < need then
    return nil, bestHits, #objs
  end
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
  local limit = math.min(opts.limit or arizona.MAX_SLOTS, arizona.MAX_SLOTS)
  local withPos = opts.withPos ~= false
  local b = getBase()
  if b == 0 then return {} end

  local me = arizona.localIndex()

  -- Массив слотов читается одним куском, поля — пакетами: так весь список
  -- игроков обходится примерно за пяток системных вызовов.
  local ptrs, slots = memory.readptrs(b + arizona.OFF_PLAYER_ARRAY, limit,
                                      arizona.SLOT_STRIDE)
  if not ptrs or #ptrs == 0 then return {} end

  local pos, posOk, veh, inVeh
  if withPos then
    pos, posOk = memory.gather(ptrs, arizona.OFF_POS, 'f32x3')
    veh = memory.gather(ptrs, arizona.OFF_VEHICLE, 'ptr')
    inVeh = memory.gather(ptrs, arizona.OFF_IN_VEH, 'u8')
  end

  local out = {}
  for i = 1, #ptrs do
    local idx = slots[i]
    if not (opts.skipLocal and idx == me) then
      local rec = { index = idx, ptr = ptrs[i], isLocal = (idx == me) }
      if withPos then
        rec.inVehicle = (inVeh[i] ~= 0) and sanePointer(veh[i]) or false
        rec.vehicle = rec.inVehicle and veh[i] or nil
        if posOk[i] then
          local o = (i - 1) * 3
          local x, y, z = pos[o + 1], pos[o + 2], pos[o + 3]
          if saneCoord(x) and saneCoord(y) and saneCoord(z) then
            rec.x, rec.y, rec.z = x, y, z
          end
        end
        -- В транспорте координаты живут в объекте транспорта.
        if rec.inVehicle then
          local vx, vy, vz = arizona.position(rec.vehicle)
          if vx then rec.x, rec.y, rec.z = vx, vy, vz end
        end
        if rec.x then out[#out + 1] = rec end
      else
        out[#out + 1] = rec
      end
    end
  end
  return out
end

-- ═══════════════════════════════════════════════════════════════ текст
--
-- Ник, название и прочие подписи движок держит в std::string. У libc++
-- короткая строка лежит прямо в объекте: первый байт — длина, сдвинутая на
-- бит, дальше сами символы. Длинная — указатель, длина и ёмкость. Оба вида
-- распознаются здесь, поэтому искать подпись можно, ничего не зная о том,
-- какой она длины.

local function printableRun(bytes)
  local n = 0
  for i = 1, #bytes do
    local c = bytes:byte(i)
    if c == 0 then break end
    -- Печатная латиница, знаки и старшая половина: там кириллица UTF-8.
    if c < 0x20 or c == 0x7F then return nil end
    n = n + 1
  end
  return n
end

-- Читает строку по адресу: сначала как std::string, потом как обычную
-- нуль-терминированную. Возвращает текст и вид ('короткая', 'длинная',
-- 'c-строка'), либо nil.
function arizona.readText(addr, maxLen)
  maxLen = maxLen or 128
  if not sanePointer(addr) then return nil end

  local head = memory.readbytes(addr, 24)
  if not head or #head < 24 then return nil end

  -- Длинная строка libc++: [0..7] данные, [8..15] длина, старший бит
  -- ёмкости взведён.
  local dataPtr = memory.deref(addr)
  local len = memory.readu32(addr + 8)
  if sanePointer(dataPtr) and len and len > 0 and len <= maxLen then
    local body = memory.readbytes(dataPtr, len)
    if body and #body == len and printableRun(body) == len then
      return body, 'длинная'
    end
  end

  -- Короткая строка libc++: длина в первом байте, сдвинутая влево на бит.
  local first = head:byte(1)
  local shortLen = math.floor(first / 2)
  if first % 2 == 0 and shortLen >= 1 and shortLen <= 22 then
    local body = head:sub(2, 1 + shortLen)
    if #body == shortLen and printableRun(body) == shortLen
       and head:byte(2 + shortLen) == 0 then
      return body, 'короткая'
    end
  end

  -- Просто char[]: текст лежит с самого начала.
  local raw = memory.readbytes(addr, maxLen)
  if raw then
    local n = printableRun(raw)
    if n and n >= 3 then return raw:sub(1, n), 'c-строка' end
  end
  return nil
end

-- Перебирает блок памяти и собирает всё, что похоже на текст: и сами
-- строки, и указатели на них. Так находится ник — не зная его смещения,
-- достаточно узнать себя в списке.
--
-- Возвращает список { off = смещение, kind = вид, text = текст }.
function arizona.findTexts(addr, size, opts)
  opts = opts or {}
  local minLen = opts.minLen or 3
  local out = {}
  if not sanePointer(addr) then return out end

  local blockSize = math.min(size or 512, 65536)
  local block = memory.readbytes(addr, blockSize)
  if not block then return out end

  local seen = {}
  for off = 0, #block - 1 do
    -- Текст прямо в блоке.
    local tail = block:sub(off + 1, math.min(off + 64, #block))
    local n = printableRun(tail)
    if n and n >= minLen and not seen[off] then
      local text = tail:sub(1, n)
      out[#out + 1] = { off = off, kind = 'в блоке', text = text }
      for k = off, off + n - 1 do seen[k] = true end
    end
  end

  -- Указатели на текст: каждые 8 байт по выравниванию.
  for off = 0, #block - 8, 8 do
    local lo = 0
    for k = 7, 0, -1 do lo = lo * 256 + block:byte(off + k + 1) end
    local p = lo % 0x1000000000000
    if sanePointer(p) then
      local text, kind = arizona.readText(addr + off)
      if text and #text >= minLen then
        out[#out + 1] = { off = off, kind = kind, text = text }
      end
    end
  end

  table.sort(out, function(a, c) return a.off < c.off end)
  return out
end

-- Адрес самого слота игрока (не объекта): 336 байт, в начале указатель.
function arizona.slotAddr(index)
  local b = getBase()
  if b == 0 or not index then return nil end
  return b + arizona.OFF_PLAYER_ARRAY + index * arizona.SLOT_STRIDE
end

-- Смещение ника в слоте. Определяется на живой игре: находится тот текст,
-- который совпадает у своего слота с известным ником.
arizona.nickOffset = nil

function arizona.nick(index)
  if not arizona.nickOffset then return nil end
  local a = arizona.slotAddr(index)
  if not a then return nil end
  return arizona.readText(a + arizona.nickOffset)
end

-- Ищет смещение ника: перебирает тексты в слоте и берёт тот, что совпал
-- с переданным ником. Смещение общее для всех слотов.
function arizona.findNickOffset(nick, index)
  index = index or arizona.localIndex()
  if not index then return nil, 'слот не определён' end
  local a = arizona.slotAddr(index)
  if not a then return nil, 'база не найдена' end

  local list = arizona.findTexts(a, arizona.SLOT_STRIDE)
  for _, t in ipairs(list) do
    if t.text == nick then
      arizona.nickOffset = t.off
      return t.off, t.kind
    end
  end
  for _, t in ipairs(list) do
    if t.text:find(nick, 1, true) then
      arizona.nickOffset = t.off
      return t.off, t.kind
    end
  end
  return nil, 'такой текст в слоте не встретился'
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
  if arizona.nickOffset then
    f:write(('nickOff=%d\n'):format(arizona.nickOffset))
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
    elseif k == 'nickOff' then arizona.nickOffset = tonumber(v)
    end
  end
  f:close()
  return true
end

return arizona
