-- Проверка lib/arizona на настоящем Lua с поддельной памятью.
--
-- Нужна по горькому опыту: правка библиотеки однажды снесла целый кусок
-- вместе с таблицей arizona.cam и поиском камеры, и ни синтаксис, ни прогон
-- скриптов этого не заметили — до игры. Здесь проверяется, что все нужные
-- функции на месте и что проекция считает то, что должна.

local root = os.getenv('AGL_ROOT') or '.'
package.path = root .. '/lib/?.lua;' .. root .. '/lib/?/init.lua;' .. package.path

local fails = 0
local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then
    io.write(('  ok        %s\n'):format(name))
  else
    fails = fails + 1
    io.write(('  ПРОВАЛ    %-40s %s\n'):format(name, tostring(err)))
  end
end

-- ═════════════════════════════════════════════════ поддельная память

-- Расклад: rw::engine -> камера -> кадр. Матрица кадра единичная и
-- повёрнута так, чтобы камера стояла в начале координат и смотрела по +Y.
local BASE   = 0x70000000
local ENGINE = 0x10000000
local CAMERA = 0x11000000
local FRAME  = 0x12000000

-- Камера смотрит вдоль +Y, вверх +Z, правая ось +X.
local LTM = {
  1, 0, 0,      -- right
  0, 0, 1,      -- up
  0, 1, 0,      -- at
  0, 0, 0,      -- pos
}
local VIEWW = { 0.5, 0.5 }   -- тангенс половины поля зрения

local arizona
local A       -- смещения, заполняются после require

memory = {
  getclientbase = function() return BASE end,
  deref = function(addr)
    if addr == BASE + A.OFF_RW_ENGINE then return ENGINE end
    if addr == ENGINE + A.OFF_ENG_CAMERA then return CAMERA end
    if addr == CAMERA + A.OFF_CAM_FRAME then return FRAME end
    return nil
  end,
  readfloat = function(addr)
    local ltm = FRAME + A.OFF_FRAME_LTM
    if addr == CAMERA + A.OFF_CAM_VIEWW then return VIEWW[1] end
    if addr == CAMERA + A.OFF_CAM_VIEWW + 4 then return VIEWW[2] end
    if addr >= ltm and addr < ltm + 64 then
      local off = addr - ltm
      local row = math.floor(off / 16)
      local col = math.floor((off % 16) / 4)
      if col > 2 then return 0 end
      return LTM[row * 3 + col + 1]
    end
    return nil
  end,
  gather = function(addrs, off, kind)
    local vals, ok = {}, {}
    for i, a in ipairs(addrs) do
      ok[i] = true
      if kind == 'f32x3' then
        for c = 0, 2 do
          vals[(i - 1) * 3 + c + 1] = memory.readfloat(a + off + c * 4) or 0
        end
      else
        vals[i] = 0
      end
    end
    return vals, ok
  end,
  readu8 = function() return 0 end,
  readu16 = function() return 0 end,
  readu32 = function() return 0 end,
  readi16 = function() return 0 end,
  readi32 = function() return 0 end,
  writeu8 = function() return true end,
  writei32 = function() return true end,
  readptrs = function() return {}, {} end,
  readbytes = function() return nil end,
  readmatrix = function() return nil end,
  findmatrix = function() return nil, 'нет' end,
  findpointerto = function() return {} end,
}

function getScreenSize() return 1000, 500 end
function getPaths() return { config = '/tmp' } end
function log() end

arizona = require 'arizona'
A = arizona

-- ═══════════════════════════════════════════════════════ проверки

check('все нужные функции на месте', function()
  local need = {
    'localPlayer', 'position', 'velocity', 'speedKmh', 'inVehicle', 'players',
    'entities', 'poolObjects', 'poolArray', 'poolProbe', 'modelInfo',
    'findPoolPositionOffset', 'findEntityArrays',
    'readText', 'findTexts', 'nick', 'findNickOffset', 'playerTexts',
    'time', 'setTime', 'timeSpeed', 'setTimeSpeed', 'engineMs', 'lightning',
    'timecycleEditor', 'timecycleSlot', 'radar', 'setRadarShown',
    'rwEngine', 'rwCamera', 'cameraView', 'cameraFrame', 'cameraPose', 'fov',
    'rwWorldToScreen', 'worldToScreen', 'beginFrame', 'cameraMatrix',
    'findCamera', 'ensureCamera', 'saveProjection', 'loadProjection',
  }
  for _, name in ipairs(need) do
    assert(type(arizona[name]) == 'function', 'нет функции ' .. name)
  end
  assert(type(arizona.cam) == 'table', 'нет таблицы cam')
  assert(type(arizona.POOLS) == 'table', 'нет списка пулов')
end)

check('камера движка читается', function()
  assert(arizona.rwEngine() == ENGINE, 'не тот engine')
  assert(arizona.rwCamera() == CAMERA, 'не та камера')
  local v = assert(arizona.cameraView(), 'вид не собрался')
  assert(v.rx == 1 and v.uz == 1 and v.ay == 1,
         'оси разобраны неверно: ' .. v.rx .. ' ' .. v.uz .. ' ' .. v.ay)
  assert(v.px == 0 and v.py == 0 and v.pz == 0,
         'позиция камеры не на месте: ' .. tostring(v.px))
end)

check('поле зрения', function()
  local f = assert(arizona.fov(), 'не посчиталось')
  -- tan(угол/2) = 0.5 -> угол около 53 градусов
  assert(math.abs(f - 53.13) < 0.5, 'вышло ' .. f)
end)

check('точка прямо по курсу — в центре экрана', function()
  local v = arizona.cameraView()
  local x, y = arizona.rwWorldToScreen(0, 10, 0, 1000, 500, v)
  assert(x, 'не спроецировалась')
  assert(math.abs(x - 500) < 0.01 and math.abs(y - 250) < 0.01,
         ('вышло %.2f %.2f'):format(x, y))
end)

check('точка справа — в правой половине', function()
  local v = arizona.cameraView()
  -- Правая ось камеры это +X, но пространство вида левостороннее, поэтому
  -- смещение по +X уходит на экране влево — так считает и сам движок.
  local x = arizona.rwWorldToScreen(1, 10, 0, 1000, 500, v)
  assert(x < 500, 'ожидали левее центра, вышло ' .. x)
  local x2 = arizona.rwWorldToScreen(-1, 10, 0, 1000, 500, v)
  assert(x2 > 500, 'ожидали правее центра, вышло ' .. x2)
end)

check('точка выше — в верхней половине', function()
  local v = arizona.cameraView()
  local _, y = arizona.rwWorldToScreen(0, 10, 1, 1000, 500, v)
  assert(y < 250, 'ожидали выше центра, вышло ' .. y)
end)

check('точка за спиной отсеивается', function()
  local v = arizona.cameraView()
  assert(arizona.rwWorldToScreen(0, -10, 0, 1000, 500, v) == nil,
         'спроецировалась точка позади камеры')
end)

check('дальше — ближе к центру', function()
  local v = arizona.cameraView()
  local near = arizona.rwWorldToScreen(1, 5, 0, 1000, 500, v)
  local far  = arizona.rwWorldToScreen(1, 50, 0, 1000, 500, v)
  assert(math.abs(far - 500) < math.abs(near - 500),
         'перспектива не работает')
end)

check('beginFrame отдаёт вид', function()
  local v = assert(arizona.beginFrame(), 'ничего не вернул')
  assert(v.wx == 0.5, 'окно вида не то')
  assert(arizona.rwMatrixCache == v, 'кеш не выставлен')
end)

check('worldToScreen идёт через камеру движка', function()
  arizona.beginFrame()
  local x, y = arizona.worldToScreen(0, 10, 0, 1000, 500)
  assert(x and math.abs(x - 500) < 0.01 and math.abs(y - 250) < 0.01,
         'через общую точку входа вышло другое')
end)

io.write(('провалов: %d\n'):format(fails))
os.exit(fails == 0 and 0 or 1)
