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

-- Пробовали ли уже подобрать смещение позиции на живой игре. Нужен, чтобы
-- подбор случился один раз, а не на каждом кадре.
arizona.posOffsetTried = false

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

-- Что лежит в глобалах пулов прямо сейчас — для разведки. Возвращает список
-- { name, global, raw, addr, count, live }, где raw — сырое значение по
-- адресу, а addr — оно же со снятой меткой, если похоже на указатель.
function arizona.poolProbe()
  local b = getBase()
  local out = {}
  for n, p in ipairs(arizona.POOLS) do
    local rec = { name = p.name, global = p.global, count = p.count }
    if b ~= 0 then
      rec.raw = memory.readu64(b + p.global)
      local a = memory.deref(b + p.global)
      if sanePointer(a) then
        rec.addr = a
        local ptrs = memory.readptrs(a, p.count)
        rec.live = ptrs and #ptrs or 0
      end
    end
    out[n] = rec
  end
  return out
end

-- Ищет массивы, в которых лежат переданные указатели на сущности.
--
-- Нужно, когда известные адреса пулов не подошли: например, игра
-- обновилась. Работает от обратного — берём заведомо живые сущности
-- (игроков) и смотрим, откуда на них показывают. Если из одного места
-- памяти показывают на многих сразу с шагом восемь байт, это и есть массив
-- пула.
--
-- Возвращает список { addr, hits, span } — адрес предполагаемого начала,
-- сколько наших сущностей в нём нашлось и сколько мест он занимает.
function arizona.findEntityArrays(ptrs, opts)
  opts = opts or {}
  local minHits = opts.minHits or 4

  if not ptrs then
    ptrs = {}
    for _, p in ipairs(arizona.players({ withPos = false })) do
      ptrs[#ptrs + 1] = p.ptr
    end
  end
  if #ptrs == 0 then return {}, 'нет ни одной известной сущности' end

  -- Больше десятка проб не нужно: массив выдаст себя и на них, а каждый
  -- поиск — это проход по всей памяти.
  local probes = math.min(#ptrs, opts.probes or 8)

  local hits = {}
  for i = 1, probes do
    local list = memory.findpointerto(ptrs[i], { where = opts.where or 'all' })
    for _, addr in ipairs(list or {}) do
      hits[#hits + 1] = addr
    end
  end
  if #hits == 0 then return {}, 'на сущности никто не показывает' end

  table.sort(hits)

  -- Собираем подряд идущие места: разрыв больше килобайта — это уже другой
  -- массив, а не дырка в этом.
  local groups = {}
  local cur = { from = hits[1], to = hits[1], n = 1 }
  for i = 2, #hits do
    if hits[i] - cur.to <= 1024 then
      cur.to = hits[i]
      cur.n = cur.n + 1
    else
      groups[#groups + 1] = cur
      cur = { from = hits[i], to = hits[i], n = 1 }
    end
  end
  groups[#groups + 1] = cur

  local out = {}
  for _, g in ipairs(groups) do
    if g.n >= minHits then
      out[#out + 1] = {
        addr = g.from, hits = g.n,
        span = math.floor((g.to - g.from) / 8) + 1,
      }
    end
  end
  table.sort(out, function(a, c) return a.hits > c.hits end)
  return out
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
  local seen = 0     -- сколько живых сущностей вообще попалось

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
        seen = seen + #ptrs
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

  -- Сущности в пулах есть, а рядом с игроком ни одной — значит смещение
  -- позиции не то. Подбираем его сами и повторяем: заставлять пользователя
  -- жать кнопку в разведке ради этого незачем.
  if near and #out == 0 and seen > 50 and not arizona.posOffsetTried then
    arizona.posOffsetTried = true
    local found = arizona.findPoolPositionOffset(nx, ny, nz)
    if found and found ~= off then
      return arizona.entities(opts)
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

-- Где лежит ник. Определяется на живой игре: находится тот текст, который
-- совпал с известным ником, и запоминается место — слот игрока или сама
-- сущность. Смещение общее для всех игроков.
arizona.nickOffset = nil
arizona.nickWhere  = 'слот'    -- 'слот' или 'сущность'

local function nickBase(index)
  if arizona.nickWhere == 'сущность' then
    return arizona.playerPtr(index)
  end
  return arizona.slotAddr(index)
end

function arizona.nick(index)
  if not arizona.nickOffset then return nil end
  local a = nickBase(index)
  if not a then return nil end
  return arizona.readText(a + arizona.nickOffset)
end

-- Ищет ник и там, и там: в 336-байтовом слоте и в начале объекта сущности.
-- Возвращает смещение, вид строки и где нашлось.
function arizona.findNickOffset(nick, index, opts)
  opts = opts or {}
  index = index or arizona.localIndex()
  if not index then return nil, 'слот не определён' end

  local places = {
    { where = 'слот',     addr = arizona.slotAddr(index),
      size = arizona.SLOT_STRIDE },
    { where = 'сущность', addr = arizona.playerPtr(index),
      size = opts.entitySize or 4096 },
  }

  local partial
  for _, place in ipairs(places) do
    if place.addr then
      for _, t in ipairs(arizona.findTexts(place.addr, place.size)) do
        if t.text == nick then
          arizona.nickOffset, arizona.nickWhere = t.off, place.where
          return t.off, t.kind, place.where
        end
        if not partial and t.text:find(nick, 1, true) then
          partial = { off = t.off, kind = t.kind, where = place.where }
        end
      end
    end
  end

  if partial then
    arizona.nickOffset, arizona.nickWhere = partial.off, partial.where
    return partial.off, partial.kind, partial.where
  end
  return nil, 'такого текста ни в слоте, ни в сущности нет'
end

-- Все тексты игрока разом — и из слота, и из сущности. Для разведки:
-- в списке видно и ник, и всё остальное, что движок держит строками.
function arizona.playerTexts(index, opts)
  opts = opts or {}
  index = index or arizona.localIndex()
  local out = {}
  if not index then return out end

  local function add(where, addr, size)
    if not addr then return end
    for _, t in ipairs(arizona.findTexts(addr, size)) do
      t.where = where
      out[#out + 1] = t
    end
  end

  add('слот', arizona.slotAddr(index), arizona.SLOT_STRIDE)
  add('сущность', arizona.playerPtr(index), opts.entitySize or 4096)
  return out
end

function arizona.distanceTo(ptr, x, y, z)
  local px, py, pz = arizona.position(ptr)
  if not px then return nil end
  local dx, dy, dz = px - x, py - y, pz - z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ═══════════════════════════════════════════════════════ время суток
--
-- Найдено декомпиляцией. В движке есть отладочное окно «Timecycle editor»,
-- и рядом с ним — функция, которая выбирает две точки суток и смешивает их.
-- Она начинается так:
--
--   fVar70 = (float)*0x113E028;                       -- минуты
--   fVar90 = (float)*0x113E024;                       -- часы
--   fVar90 = fVar70/60.0 + *0x113E02C/3600.0 + fVar90;
--   if (23.999 < fVar90) fVar90 = 23.999;
--
-- А сам ход часов — в тике мира:
--
--   if (*0x113E030 < *0x1318F30 - *0x113E034) {
--       *0x113E034 += *0x113E030;
--       if (++*0x113E028 > 59) { *0x113E028 = 0;
--                                if (++*0x113E024 > 23) *0x113E024 = 0; }
--   }
--
-- Отсюда всё: и где лежат часы с минутами, и чем задаётся скорость хода.

arizona.OFF_CLOCK_INSTANT = 0x113E020  -- uint8, перещёлкнуть время сразу
arizona.OFF_HOUR          = 0x113E024  -- uint8, 0..23
arizona.OFF_MINUTE        = 0x113E028  -- uint8, 0..59
arizona.OFF_SECOND        = 0x113E02C  -- uint16, считается от остатка
arizona.OFF_MINUTE_MS     = 0x113E030  -- int32, миллисекунд на игровую минуту
arizona.OFF_CLOCK_TICK    = 0x113E034  -- int32, когда была прошлая минута
arizona.OFF_ENGINE_MS     = 0x1318F30  -- uint32, время движка, 391 ссылка

-- Вспышка молнии: счётчик, который поднимает яркость сцены.
arizona.OFF_LIGHTNING     = 0x35E4E9C  -- int32

function arizona.time()
  local b = getBase()
  if b == 0 then return nil end
  local h = memory.readu8(b + arizona.OFF_HOUR)
  local m = memory.readu8(b + arizona.OFF_MINUTE)
  if not h or not m then return nil end
  return h, m, memory.readu16(b + arizona.OFF_SECOND) or 0
end

-- Ставит время. Это клиентская подсветка: сервер своё время не меняет и
-- при следующей рассинхронизации может вернуть своё.
function arizona.setTime(hour, minute)
  local b = getBase()
  if b == 0 then return false end
  hour = math.max(0, math.min(23, math.floor(tonumber(hour) or 0)))
  minute = math.max(0, math.min(59, math.floor(tonumber(minute) or 0)))
  local ok = memory.writeu8(b + arizona.OFF_HOUR, hour)
  ok = memory.writeu8(b + arizona.OFF_MINUTE, minute) and ok
  return ok and true or false
end

-- Сколько миллисекунд идёт игровая минута. Ноль останавливает часы.
function arizona.timeSpeed()
  local b = getBase()
  if b == 0 then return nil end
  return memory.readi32(b + arizona.OFF_MINUTE_MS)
end

function arizona.setTimeSpeed(ms)
  local b = getBase()
  if b == 0 then return false end
  ms = math.max(0, math.floor(tonumber(ms) or 1000))
  return memory.writei32(b + arizona.OFF_MINUTE_MS, ms) and true or false
end

-- Время движка в миллисекундах: им меряются все его собственные задержки.
function arizona.engineMs()
  local b = getBase()
  if b == 0 then return nil end
  return memory.readu32(b + arizona.OFF_ENGINE_MS)
end

-- Встроенный в движок редактор таймцикла. Это его собственное отладочное
-- окно на ImGui: освещение, туман, дальность прорисовки, небо и
-- постобработка по восьми точкам суток, с сохранением в DATA/TIMECYC.JSON.
-- Скомпилировано в релизную сборку, просто выключено флагом.
arizona.OFF_TC_EDITOR = 0x35E5028   -- bool, показывать окно
arizona.OFF_TC_SLOT   = 0x35E5024   -- int32, выбранная точка суток, 0..7

function arizona.timecycleEditor(on)
  local b = getBase()
  if b == 0 then return nil end
  if on ~= nil then
    memory.writeu8(b + arizona.OFF_TC_EDITOR, on and 1 or 0)
  end
  return (memory.readu8(b + arizona.OFF_TC_EDITOR) or 0) ~= 0
end

function arizona.timecycleSlot(slot)
  local b = getBase()
  if b == 0 then return nil end
  if slot then
    memory.writei32(b + arizona.OFF_TC_SLOT,
                    math.max(0, math.min(7, math.floor(slot))))
  end
  return memory.readi32(b + arizona.OFF_TC_SLOT)
end

function arizona.lightning(strength)
  local b = getBase()
  if b == 0 then return nil end
  if strength then
    memory.writei32(b + arizona.OFF_LIGHTNING,
                    math.max(0, math.floor(strength)))
  end
  return memory.readi32(b + arizona.OFF_LIGHTNING)
end

-- ═══════════════════════════════════════════════════════════════ радар
--
-- Найдено через JNI-методы SetupHudDisplay и drawGameRadarCircle: сами они
-- только кладут задачу в очередь, а глобалы пишет уже обработчик
-- (0x74A6FC и 0x74A79C). Java эти методы не зовёт, но код отрисовки радара
-- те же глобалы читает — значит, состояние настоящее.

arizona.RADAR = {
  shown  = 0x9AF7B8,    -- uint8, показан ли
  round  = 0x117E384,   -- uint8, круглый (1) или прямоугольный (0)
  radius = 0x9948B0,    -- float
  x      = 0x9948B4,    -- float, на экране
  y      = 0x9948B8,    -- float, на экране
}

-- Где радар на экране и виден ли он. Скриптам это нужно, чтобы не рисовать
-- поверх него.
function arizona.radar()
  local b = getBase()
  if b == 0 then return nil end
  local r = arizona.RADAR
  return {
    shown  = (memory.readu8(b + r.shown) or 0) ~= 0,
    round  = (memory.readu8(b + r.round) or 0) ~= 0,
    radius = memory.readfloat(b + r.radius),
    x      = memory.readfloat(b + r.x),
    y      = memory.readfloat(b + r.y),
  }
end

function arizona.setRadarShown(on)
  local b = getBase()
  if b == 0 then return false end
  return memory.writeu8(b + arizona.RADAR.shown, on and 1 or 0) and true or false
end

-- ═══════════════════════════════════════════════ камера движка (librw)
--
-- Движок рисует на librw — это видно по путям исходников в самой
-- библиотеке (/usr/src/vendor/librw/src/*.cpp). А раз так, у него есть
-- rw::engine, и от него дорога к камере известна по исходникам librw, а не
-- на глазок.
--
-- Опознан он через defaultBeginUpdateCB. В librw эта функция выглядит так:
--
--   engine->currentCamera = cam;
--   Frame::syncDirty();
--   engine->device.beginUpdate(cam);
--
-- А в библиотеке по 0x298018 лежит ровно она:
--
--   adrp x20, 0x974000
--   ldr  x20, [x20, #2944]    ; GOT -> 0x9C1A00, это и есть rw::engine
--   ldr  x8,  [x20]           ; сам Engine
--   str  x0,  [x8]            ; engine->currentCamera = cam   (смещение 0)
--   bl   0x29C300             ; Frame::syncDirty()
--   ldr  x1,  [x8, #152]      ; engine->device.beginUpdate
--   br   x1
--
-- Раскладка структур взята из заголовков librw и перепроверена по коду:
-- по 0x29C2D0 движок пишет в frame->ltm по смещению 112 и читает
-- privateFlags по смещению 3 — ровно как в rwobjects.h.

arizona.OFF_RW_ENGINE = 0x9C1A00   -- указатель на rw::Engine

arizona.OFF_ENG_CAMERA = 0    -- Engine::currentCamera
arizona.OFF_ENG_WORLD  = 8    -- Engine::currentWorld

arizona.OFF_CAM_FRAME  = 8    -- Camera::object.object.parent, это Frame*
arizona.OFF_CAM_VIEWW  = 56   -- Camera::viewWindow, x = tan(поле зрения / 2)
arizona.OFF_CAM_NEAR   = 72
arizona.OFF_CAM_FAR    = 76
arizona.OFF_CAM_PROJ   = 84   -- 1 — перспектива
arizona.OFF_CAM_VIEWM  = 88   -- Camera::viewMatrix, мир -> экран

arizona.OFF_FRAME_LTM  = 112  -- Frame::ltm, положение в мире
arizona.OFF_MAT_POS    = 48   -- в rw::Matrix позиция идёт четвёртой

function arizona.rwEngine()
  local b = getBase()
  if b == 0 then return nil end
  local e = memory.deref(b + arizona.OFF_RW_ENGINE)
  return sanePointer(e) and e or nil
end

function arizona.rwCamera()
  local e = arizona.rwEngine()
  if not e then return nil end
  local c = memory.deref(e + arizona.OFF_ENG_CAMERA)
  return sanePointer(c) and c or nil
end

-- Всё, что нужно для проекции, одним чтением: положение камеры, её оси и
-- размер окна вида. Возвращает таблицу либо nil.
--
-- Матрицу Camera::viewMatrix брать нельзя, хотя соблазн есть: у rw::Matrix
-- нет четвёртой строки, и как матрица отсечения на OpenGL она не работает —
-- отсюда и были отметки, слипшиеся в углу экрана. Бэкенд GL строит свои
-- матрицы сам, из ltm кадра камеры и viewWindow, и здесь считается ровно
-- то же самое.
function arizona.cameraView()
  local c = arizona.rwCamera()
  if not c then return nil end
  local f = memory.deref(c + arizona.OFF_CAM_FRAME)
  if not sanePointer(f) then return nil end

  local ltm = f + arizona.OFF_FRAME_LTM
  -- Четыре вектора матрицы и окно вида одной пачкой.
  local rows = { ltm, ltm + 16, ltm + 32, ltm + 48 }
  local v, ok = memory.gather(rows, 0, 'f32x3')
  if not v then return nil end
  for i = 1, 4 do
    if not ok[i] then return nil end
  end
  for i = 1, 12 do
    if not v[i] or v[i] ~= v[i] then return nil end
  end

  local wx = memory.readfloat(c + arizona.OFF_CAM_VIEWW)
  local wy = memory.readfloat(c + arizona.OFF_CAM_VIEWW + 4)
  if not wx or not wy or wx ~= wx or wy ~= wy then return nil end
  if wx <= 0.001 or wy <= 0.001 or wx > 10 or wy > 10 then return nil end

  -- gather с 'f32x3' кладёт по три числа на строку подряд, без выравнивания:
  -- строка N занимает v[(N-1)*3+1 .. (N-1)*3+3].
  return {
    rx = v[1],  ry = v[2],  rz = v[3],     -- правая ось
    ux = v[4],  uy = v[5],  uz = v[6],     -- верх
    ax = v[7],  ay = v[8],  az = v[9],     -- вперёд
    px = v[10], py = v[11], pz = v[12],    -- где стоит камера
    wx = wx, wy = wy,
  }
end

-- Мировые координаты в экранные.
--
-- Считается так же, как это делает бэкенд GL у librw:
--
--   v.x = -( (p - камера) . правая )   -- ось X он переворачивает,
--   v.y =  ( (p - камера) . верх )     -- чтобы пространство вида стало
--   v.z =  ( (p - камера) . вперёд )   -- левосторонним
--   экран.x = ширина  * (0.5 + v.x / (2 * окно.x * v.z))
--   экран.y = высота  * (0.5 - v.y / (2 * окно.y * v.z))
--
-- Ни поля зрения, ни соотношения сторон подставлять не надо: и то и другое
-- уже сидит в окне вида, которое движок пересчитывает сам.
--
-- Возвращает x, y и расстояние вдоль взгляда, либо nil, если точка позади.
function arizona.rwWorldToScreen(wx, wy, wz, sw, sh, cam)
  cam = cam or arizona.cameraView()
  if not cam then return nil end
  if not sw then sw, sh = getScreenSize() end
  if not sw or sw == 0 then return nil end

  local dx, dy, dz = wx - cam.px, wy - cam.py, wz - cam.pz

  local depth = dx * cam.ax + dy * cam.ay + dz * cam.az
  if depth <= 0.05 then return nil end

  -- Знак взят из бэкенда GL самого librw: он переворачивает ось X, чтобы
  -- пространство вида стало левосторонним. Оставлен переключателем на
  -- случай, если в этой сборке движка сделано иначе, — тогда отметки будут
  -- зеркальными, и это чинится галочкой, а не пересборкой.
  local side = dx * cam.rx + dy * cam.ry + dz * cam.rz
  if arizona.flipX ~= false then side = -side end
  local up   =   dx * cam.ux + dy * cam.uy + dz * cam.uz

  local x = sw * (0.5 + side / (2 * cam.wx * depth))
  local y = sh * (0.5 - up   / (2 * cam.wy * depth))
  return x, y, depth
end

-- ══════════════════════════════════════════════ камера по форме данных
--
-- Запасной путь на случай, если движок обновится и rw::engine уедет:
-- камера ищется среди матриц памяти как единственная, что стоит в
-- нескольких метрах от игрока и смотрит прямо на него. Поле зрения и оси
-- при этом подбираются вручную — поэтому путь и запасной.

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

-- Кадр камеры движка: в нём лежит её положение в мире.
function arizona.cameraFrame()
  local c = arizona.rwCamera()
  if not c then return nil end
  local f = memory.deref(c + arizona.OFF_CAM_FRAME)
  return sanePointer(f) and f or nil
end

-- Где стоит камера и куда смотрит. Нужно всему, что считает направление:
-- автопилоту, чтобы понять, куда толкать джойстик, и разведке.
function arizona.cameraPose()
  local v = arizona.cameraView()
  if not v then return nil end
  return v.px, v.py, v.pz, v.ax, v.ay, v.az
end

-- Поле зрения по горизонтали в градусах, прямо из камеры.
function arizona.fov()
  local c = arizona.rwCamera()
  if not c then return nil end
  -- viewWindow.x — это тангенс половины поля зрения по горизонтали.
  local w = memory.readfloat(c + arizona.OFF_CAM_VIEWW)
  if not w or w ~= w or w <= 0.01 or w > 10 then return nil end
  return math.deg(math.atan(w)) * 2
end

-- Поднимает камеру, если её ещё нет: сперва из сохранённых настроек, потом
-- поиском по памяти. Скрипты с ESP зовут это сами, чтобы не заставлять
-- открывать разведку вручную.
--
-- Возвращает адрес камеры либо nil и причину.
function arizona.ensureCamera()
  -- Камера движка не ищется, она просто есть: адрес rw::engine известен из
  -- разбора кода. Поиск по памяти остаётся запасным путём на случай, если
  -- игра обновится и смещение уедет.
  if arizona.useEngineCamera then
    local c = arizona.rwCamera()
    if c and arizona.cameraView() then
      arizona.cam.addr = c
      arizona.cam.fov = math.floor((arizona.fov() or 70) + 0.5)
      return c, 'камера движка'
    end
  end

  if arizona.cam.addr ~= 0 and arizona.cameraMatrix() then
    return arizona.cam.addr
  end

  arizona.loadProjection()
  if arizona.cam.addr ~= 0 and arizona.cameraMatrix() then
    return arizona.cam.addr
  end

  local addr, acc = arizona.findCamera()
  if not addr then return nil, tostring(acc) end
  arizona.saveProjection()
  return addr, acc
end

-- Матрица камеры, найденной поиском по памяти. Когда работает камера
-- движка, этого пути нет вовсе: cam.addr тогда указывает на rw::Camera, а
-- читать её как матрицу положения бессмысленно.
function arizona.cameraMatrix()
  if arizona.useEngineCamera and arizona.rwCamera() then return nil end
  if arizona.cam.addr == 0 then return nil end
  return memory.readmatrix(arizona.cam.addr)
end

-- Матрица движка живёт один кадр: её надо перечитывать, но не по разу на
-- каждый объект. Скрипты зовут это в начале отрисовки.
arizona.rwMatrixCache = nil
arizona.useEngineCamera = true
arizona.flipX = true

function arizona.beginFrame()
  arizona.rwMatrixCache = arizona.useEngineCamera and arizona.cameraView() or nil
  return arizona.rwMatrixCache
end

-- Мировые координаты в экранные. Возвращает x, y и расстояние до камеры,
-- либо nil, если точка за спиной.
function arizona.worldToScreen(wx, wy, wz, sw, sh, cam)
  -- Если матрица движка на месте — считаем по ней: там уже и поле зрения, и
  -- соотношение сторон, и развороты осей, подбирать нечего.
  if arizona.useEngineCamera ~= false then
    local m = arizona.rwMatrixCache
    if m then
      local x, y, d = arizona.rwWorldToScreen(wx, wy, wz, sw, sh, m)
      if x then return x, y, d end
      return nil
    end
  end

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
  f:write(('flipX=%s\n'):format(tostring(arizona.flipX)))
  if arizona.nickOffset then
    f:write(('nickOff=%d\nnickWhere=%s\n')
            :format(arizona.nickOffset, arizona.nickWhere))
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
    elseif k == 'nickWhere' then arizona.nickWhere = v
    elseif k == 'flipX' then arizona.flipX = (v == 'true')
    end
  end
  f:close()
  return true
end

return arizona
