-- RenderObjects — порт скрипта Victor Strand под AGLoader.
--
-- Открыть: /renderob        Скан: /robjscan
--
-- Оригинал построен на функциях MoonLoader/SA-MP: getAllObjects,
-- getObjectCoordinates, convert3DCoordsToScreen, sampGetObjectSampIdByHandle.
-- В новом движке Arizona нет ни SCM-машины, ни SA-MP, поэтому этих функций
-- не существует. Перенесено всё, что от них не зависит: интерфейс целиком,
-- конфиг, чат-команды и вся отрисовка. Источник объектов вынесен в одну
-- функцию collectObjects() — как только адреса пула объектов и матрицы
-- вида-проекции будут найдены, ESP оживёт без правок остального кода.

script_name('RenderObjects')
script_author('Victor Strand')
script_version('2.4-agloader')

local ag = require 'arizona'

-- Интерфейс загрузчика поднимается позже, чем читается файл скрипта, поэтому
-- на этапе загрузки и масштаб, и размер экрана ещё нулевые. Обновляем их
-- каждый кадр — это два чтения переменных, не накладно.
local MDS    = 1
local sw, sh = 1280, 720

local function refreshMetrics()
  local s = getUiScale()
  if s and s > 0 then MDS = s end
  local w, h = getScreenSize()
  if w and w > 0 then sw, sh = w, h end
end

-- ═══════════════════════════════════════════════════════════════ состояние

local entries  = {}
local winOpen  = false
local scanMode = false

local colLine = { 0.85, 0.10, 0.10, 0.90 }
local colText = { 0.20, 1.00, 0.35, 1.00 }
local colInfo = { 1.00, 0.85, 0.20, 1.00 }
local renderRadius = 50
local chatAlert    = false

local alertShown = {}
local objCache   = {}

-- Счётчики для вкладки Info: молчаливый ESP отличается от сломанного только
-- цифрами, поэтому они всегда на виду.
local diag = {
  pool    = 0,   -- занятых мест в пуле
  near    = 0,   -- из них в радиусе
  onScreen = 0,  -- из них попало на экран
  drawn   = 0,   -- из них подошло под список моделей
  ms      = 0,   -- сколько занял последний обход
}

-- ═════════════════════════════════════════════════════════════════ конфиг

local cfgPath = getPaths().config .. '/renderobjects.ini'

local function saveCfg()
  local f = io.open(cfgPath, 'w')
  if not f then return end
  f:write('[settings]\n')
  f:write(('colLine=%f %f %f %f\n'):format(colLine[1], colLine[2], colLine[3], colLine[4]))
  f:write(('colText=%f %f %f %f\n'):format(colText[1], colText[2], colText[3], colText[4]))
  f:write(('colInfo=%f %f %f %f\n'):format(colInfo[1], colInfo[2], colInfo[3], colInfo[4]))
  f:write(('radius=%d\n'):format(renderRadius))
  f:write(('chatAlert=%s\n'):format(tostring(chatAlert)))
  for _, e in ipairs(entries) do
    f:write(('entry=%d|%s|%s|%s\n')
      :format(e.model, e.name, tostring(e.line), tostring(e.enabled)))
  end
  f:close()
end

local function addEntry(model, name, line, enabled)
  entries[#entries + 1] = {
    model   = model or 0,
    name    = name or '',
    line    = line or false,
    enabled = enabled ~= false,
  }
end

local function loadCfg()
  local f = io.open(cfgPath, 'r')
  if not f then
    addEntry(228,  'Камень', false, false)
    addEntry(1337, 'Металл', false, false)
    saveCfg()
    return
  end
  for line in f:lines() do
    local k, v = line:match('^(%w+)=(.*)$')
    if k == 'colLine' or k == 'colText' or k == 'colInfo' then
      local t = (k == 'colLine') and colLine or (k == 'colText') and colText or colInfo
      local i = 1
      for num in v:gmatch('%S+') do t[i] = tonumber(num) or t[i]; i = i + 1 end
    elseif k == 'radius' then
      renderRadius = tonumber(v) or renderRadius
    elseif k == 'chatAlert' then
      chatAlert = (v == 'true')
    elseif k == 'entry' then
      local m, n, l, e = v:match('^(-?%d+)|([^|]*)|(%a+)|(%a+)$')
      if m then addEntry(tonumber(m), n, l == 'true', e == 'true') end
    end
  end
  f:close()
end

-- ═══════════════════════════════════════════════════ источник объектов

-- Оригинал звал getAllObjects и convert3DCoordsToScreen. Здесь то же самое
-- собирается из движка напрямую: пул сущностей найден разбором кода, а
-- камера опознаётся на живой игре — подробности в lib/arizona.lua.
--
-- Два условия, без которых рисовать нечего:
--   * найдено смещение позиции в объектах пула (кнопка в /recon или здесь);
--   * найдена камера, иначе некуда проецировать.

local sourceNote = 'не готов'

local function sourceReady()
  return ag.poolPosOffset ~= nil and ag.cam.addr ~= 0
end

-- Готовит источник: подтягивает настройки, ищет смещение и камеру.
local function prepareSource()
  ag.loadProjection()

  local me = ag.localPlayer()
  if not me then
    sourceNote = 'игрок не найден — движок ещё не прогрузился'
    return false
  end
  local px, py, pz = ag.position(me)
  if not px then
    sourceNote = 'позиция игрока не читается'
    return false
  end

  -- Смещение +56 известно из разбора кода, но игра обновляется, поэтому
  -- оно каждый раз перепроверяется на живых объектах вокруг игрока.
  local off, hits, sample = ag.findPoolPositionOffset(px, py, pz)
  if not off then
    sourceNote = ('смещение позиции в пуле не подтвердилось (%d из %d). ' ..
                  'Встаньте в застроенном месте и попробуйте снова.')
                 :format(hits or 0, sample or 0)
    return false
  end
  log(('[RenderObjects] смещение позиции в пуле: +%d (подтвердили %d из %d)')
      :format(off, hits, sample))

  if ag.cam.addr == 0 then
    local addr, acc = ag.findCamera()
    if not addr then
      sourceNote = 'камера не найдена: ' .. tostring(acc)
      return false
    end
    log(('[RenderObjects] камера 0x%X, точность %.3f'):format(addr, acc))
  end

  ag.saveProjection()
  sourceNote = 'готов'
  return true
end

local function collectObjects()
  if not sourceReady() then return {} end

  local me = ag.localPlayer()
  if not me then return {} end
  local px, py, pz = ag.position(me)
  if not px then return {} end

  local cam = ag.cameraMatrix()
  if not cam then return {} end

  local clock = os.clock or os.time
  local t0 = clock()

  -- Занятость пула считается без фильтра по радиусу: если объектов ноль,
  -- виноват пул, а если их тысячи и в радиусе ноль — смещение позиции.
  local all = ag.poolObjects({ max = 40000 })
  diag.pool = #all

  local out = {}
  local objs = {}
  local r2 = renderRadius * renderRadius
  for _, o in ipairs(all) do
    if o.x then
      local dx, dy, dz = o.x - px, o.y - py, o.z - pz
      local q = dx * dx + dy * dy + dz * dz
      if q <= r2 then
        o.dist = math.sqrt(q)
        objs[#objs + 1] = o
        if #objs >= 600 then break end
      end
    end
  end
  diag.near = #objs
  diag.ms = (clock() - t0) * 1000

  for _, o in ipairs(objs) do
    out[#out + 1] = {
      handle = o.ptr,
      model  = o.model or 0,
      sampId = o.index,
      dist   = o.dist or 0,
      wx = o.x, wy = o.y, wz = o.z,
    }
  end
  return out
end

local function haveSource()
  return sourceReady()
end

-- ══════════════════════════════════════════════════════════════ отрисовка

-- Перебор пула — это тысячи чтений памяти, каждый кадр столько нельзя.
-- Оригинал обновлял список раз в 500 мс, здесь так же: в кеше лежат мировые
-- координаты, а на экранные они пересчитываются уже каждый кадр — это
-- чистая арифметика без обращений к памяти.
local function refreshCache()
  objCache = collectObjects()

  local inRange = {}
  for _, o in ipairs(objCache) do inRange[o.handle] = true end
  for h in pairs(alertShown) do
    if not inRange[h] then alertShown[h] = nil end
  end
end

-- ESP рисуется поверх игры, окно для этого не нужно.
local function drawEsp()
  if #objCache == 0 then return end

  local cam = ag.cameraMatrix() or ag.rwMatrixCache
  if not cam then return end

  -- Игрок на экране: от него тянутся линии.
  local px, py = sw / 2, sh / 2
  local me = ag.localPlayer()
  if me then
    local mx, my, mz = ag.position(me)
    if mx then
      local ax, ay = ag.worldToScreen(mx, my, mz, sw, sh, cam)
      if ax then px, py = ax, ay end
    end
  end

  local fsz = 13 * MDS
  local onScreen, drawn = 0, 0

  for _, obj in ipairs(objCache) do
    local sx, sy = ag.worldToScreen(obj.wx, obj.wy, obj.wz, sw, sh, cam)
    if sx and sx > -200 and sx < sw + 200 and sy > -200 and sy < sh + 200 then
      onScreen = onScreen + 1

      if scanMode then
        drawn = drawn + 1
        local txt = obj.sampId and obj.sampId ~= -1
          and ('id:%d model:%d %.1fm'):format(obj.sampId, obj.model, obj.dist)
          or  ('id:- model:%d %.1fm'):format(obj.model, obj.dist)
        imgui.DrawText(sx + 4 * MDS, sy, txt, 1, 1, 1, 1)
      else
        for _, e in ipairs(entries) do
          if e.enabled and e.model == obj.model then
            drawn = drawn + 1
            local dispName = (e.name ~= '') and e.name or ('model:' .. obj.model)
            local idPart   = (obj.sampId and obj.sampId ~= -1)
                             and ('  id:' .. obj.sampId) or ''
            local infoStr  = ('%.1fm'):format(obj.dist) .. idPart
            local nameY    = sy - fsz - 4 * MDS

            -- Тень под текстом, как в оригинале: сдвиг на пиксель.
            imgui.DrawText(sx + 6 * MDS, nameY + 1, dispName, 0, 0, 0, 0.65)
            imgui.DrawText(sx + 5 * MDS, nameY, dispName,
                           colText[1], colText[2], colText[3], colText[4])
            imgui.DrawText(sx + 6 * MDS, sy + 1, infoStr, 0, 0, 0, 0.65)
            imgui.DrawText(sx + 5 * MDS, sy, infoStr,
                           colInfo[1], colInfo[2], colInfo[3], colInfo[4])

            if e.line then
              imgui.DrawLine(px, py, sx, sy, 0, 0, 0, 0.65, 3.0)
              imgui.DrawLine(px, py, sx, sy,
                             colLine[1], colLine[2], colLine[3], colLine[4], 1.5)
              imgui.DrawCircleFilled(px, py, 4 * MDS, 1, 1, 1, 0.90)
              imgui.DrawCircleFilled(sx, sy, 5 * MDS,
                                     colLine[1], colLine[2], colLine[3], 1.0)
            end

            if chatAlert and not alertShown[obj.handle] then
              alertShown[obj.handle] = true
              local idStr = (obj.sampId and obj.sampId ~= -1)
                            and (' id:' .. obj.sampId) or ''
              log(('[RenderObjects] %s model:%d%s %.1fm')
                  :format(dispName, obj.model, idStr, obj.dist))
            end
            break
          end
        end
      end
    end
  end

  diag.onScreen, diag.drawn = onScreen, drawn
end

-- ═══════════════════════════════════════════════════════════════════ стиль

-- Оригинал красит стиль один раз в OnInitialize. Здесь контекст ImGui один
-- на всех, поэтому палитра выставляется на время своего окна и снимается
-- после — иначе перекрасились бы меню загрузчика и остальные скрипты.
local STYLE_COLORS = {
  { 'Col_WindowBg',             0.06, 0.07, 0.10, 0.97 },
  { 'Col_TitleBg',              0.08, 0.08, 0.12, 1 },
  { 'Col_TitleBgActive',        0.10, 0.10, 0.15, 1 },
  { 'Col_FrameBg',              0.12, 0.13, 0.17, 1 },
  { 'Col_FrameBgHovered',       0.18, 0.20, 0.26, 1 },
  { 'Col_FrameBgActive',        0.14, 0.16, 0.21, 1 },
  { 'Col_Button',               0.55, 0.08, 0.08, 1 },
  { 'Col_ButtonHovered',        0.72, 0.12, 0.12, 1 },
  { 'Col_ButtonActive',         0.40, 0.05, 0.05, 1 },
  { 'Col_CheckMark',            0.20, 0.90, 0.45, 1 },
  { 'Col_ChildBg',              0.08, 0.09, 0.12, 1 },
  { 'Col_ScrollbarBg',          0.06, 0.07, 0.10, 1 },
  { 'Col_ScrollbarGrab',        0.45, 0.07, 0.07, 1 },
  { 'Col_ScrollbarGrabHovered', 0.60, 0.10, 0.10, 1 },
  { 'Col_Text',                 0.92, 0.92, 0.93, 1 },
  { 'Col_TextDisabled',         0.45, 0.47, 0.52, 1 },
  { 'Col_Separator',            0.20, 0.22, 0.28, 1 },
  { 'Col_Tab',                  0.10, 0.10, 0.15, 1 },
  { 'Col_TabHovered',           0.65, 0.10, 0.10, 1 },
  { 'Col_Header',               0.45, 0.07, 0.07, 0.7 },
  { 'Col_HeaderHovered',        0.60, 0.10, 0.10, 0.8 },
  { 'Col_SliderGrab',           0.55, 0.08, 0.08, 1 },
  { 'Col_SliderGrabActive',     0.72, 0.12, 0.12, 1 },
  { 'Col_PopupBg',              0.08, 0.09, 0.12, 0.98 },
}

-- Зависят от масштаба, поэтому собираются на месте, а не при загрузке файла.
local function styleVars()
  return {
    { 'StyleVar_WindowRounding',   8 * MDS },
    { 'StyleVar_FrameRounding',    5 * MDS },
    { 'StyleVar_ChildRounding',    5 * MDS },
    { 'StyleVar_GrabRounding',     5 * MDS },
    { 'StyleVar_TabRounding',      5 * MDS },
    { 'StyleVar_WindowBorderSize', 1 },
    { 'StyleVar_FrameBorderSize',  0 },
    { 'StyleVar_ItemSpacing',      8 * MDS, 6 * MDS },
    { 'StyleVar_WindowPadding',    12 * MDS, 12 * MDS },
    { 'StyleVar_FramePadding',     8 * MDS, 4 * MDS },
  }
end

local pushedVars = 0

local function pushStyle()
  for _, c in ipairs(STYLE_COLORS) do
    imgui.PushStyleColor(imgui[c[1]], c[2], c[3], c[4], c[5])
  end
  local vars = styleVars()
  for _, v in ipairs(vars) do
    imgui.PushStyleVar(imgui[v[1]], v[2], v[3])
  end
  pushedVars = #vars
end

local function popStyle()
  imgui.PopStyleVar(pushedVars)
  imgui.PopStyleColor(#STYLE_COLORS)
end

-- ══════════════════════════════════════════════════════════════════ вкладки

local WIN_W = 480

local function tabList()
  local btnW = WIN_W - 24 * MDS
  imgui.Spacing()

  imgui.PushStyleColor(imgui.Col_Text, 0.70, 0.72, 0.80, 1)
  imgui.Text('Дальность рендера:')
  imgui.PopStyleColor()
  imgui.SameLine()
  imgui.SetNextItemWidth(btnW - 145 * MDS)
  local ch, v = imgui.SliderInt('##radius', renderRadius, 1, 200,
                                tostring(renderRadius) .. ' м')
  if ch then renderRadius = v; saveCfg() end

  ch, v = imgui.Checkbox('Уведомление в чат при обнаружении', chatAlert)
  if ch then chatAlert = v; alertShown = {}; saveCfg() end

  imgui.Spacing()

  -- Шапка списка: приглушённая, колонки на фиксированных позициях.
  imgui.PushStyleVar(imgui.StyleVar_Alpha, 0.55)
  imgui.Text('Модель')
  imgui.SameLine(98 * MDS)
  imgui.Text('Название')
  imgui.SameLine(300 * MDS)
  imgui.Text('Лин')
  imgui.SameLine(336 * MDS)
  imgui.Text('Вкл')
  imgui.PopStyleVar()

  imgui.Separator()

  local listH = math.max(math.min(#entries, 6) * (24 * MDS) + 8 * MDS, 36 * MDS)
  if imgui.BeginChild('##elist', WIN_W - 26 * MDS, listH, false) then
    for i, e in ipairs(entries) do
      imgui.SetNextItemWidth(88 * MDS)
      ch, v = imgui.InputInt('##m' .. i, e.model, 0)
      if ch then e.model = v; saveCfg() end

      imgui.SameLine(0, 4 * MDS)
      imgui.SetNextItemWidth(194 * MDS)
      ch, v = imgui.InputText('##n' .. i, e.name, 64)
      if ch then e.name = v; saveCfg() end

      imgui.SameLine(0, 8 * MDS)
      ch, v = imgui.Checkbox('##l' .. i, e.line)
      if ch then e.line = v; saveCfg() end

      imgui.SameLine(0, 8 * MDS)
      ch, v = imgui.Checkbox('##e' .. i, e.enabled)
      if ch then e.enabled = v; saveCfg() end
    end
  end
  imgui.EndChild()

  imgui.Spacing()
  imgui.Separator()
  imgui.Spacing()

  if imgui.Button('+ Добавить', 140 * MDS, 0) then
    addEntry(0, '', false, true)
    saveCfg()
  end
  if #entries > 0 then
    imgui.SameLine(0, 8 * MDS)
    imgui.PushStyleColor(imgui.Col_Button,        0.28, 0.05, 0.05, 1)
    imgui.PushStyleColor(imgui.Col_ButtonHovered, 0.45, 0.08, 0.08, 1)
    imgui.PushStyleColor(imgui.Col_ButtonActive,  0.20, 0.03, 0.03, 1)
    if imgui.Button('- Убрать последний', 200 * MDS, 0) then
      table.remove(entries)
      saveCfg()
    end
    imgui.PopStyleColor(3)
  end
  imgui.Spacing()
end

local function tabColors()
  imgui.Spacing()
  local cflags = imgui.ColorEditFlags_AlphaBar +
                 imgui.ColorEditFlags_AlphaPreview +
                 imgui.ColorEditFlags_NoInputs +
                 imgui.ColorEditFlags_PickerHueBar

  local function colorRow(label, id, t)
    imgui.TextColored(label, 0.6, 0.6, 0.7, 1)
    local ch, r, g, b, a = imgui.ColorEdit4(id, t[1], t[2], t[3], t[4], cflags)
    if ch then
      t[1], t[2], t[3], t[4] = r, g, b, a
      saveCfg()
    end
    imgui.Spacing()
  end

  colorRow('Цвет линии / точек:', '##cline', colLine)
  colorRow('Цвет названия:',      '##ctext', colText)
  colorRow('Цвет дистанции / ID:', '##cinfo', colInfo)

  imgui.Separator()
  imgui.Spacing()

  imgui.TextDisabled('Превью:')
  imgui.SameLine()
  imgui.TextColored('Камень', colText[1], colText[2], colText[3], colText[4])
  imgui.SameLine(0, 16 * MDS)
  imgui.TextColored('3.5m  id:42', colInfo[1], colInfo[2], colInfo[3], colInfo[4])
  imgui.Spacing()
end

local function tabInfo()
  imgui.Spacing()
  imgui.TextColored('О скрипте', 0.80, 0.82, 0.88, 1)
  imgui.Separator()
  imgui.Spacing()

  local function row(lbl, val, r, g, b)
    imgui.TextDisabled(lbl)
    imgui.SameLine(110 * MDS)
    imgui.TextColored(val, r or 0.9, g or 0.9, b or 0.9, 1)
  end

  row('Скрипт:',   'RenderObjects v2.4')
  row('Автор:',    'Victor Strand',   0.95, 0.30, 0.30)
  row('Telegram:', '@victor_st0',     0.30, 0.70, 1.00)
  row('Каталог:',  '@strand_scripts', 0.30, 0.70, 1.00)
  row('Радиус:',   tostring(renderRadius) .. ' м (1 вплоть до 200)')
  if chatAlert then
    row('Чат-уведомления:', 'ВКЛ', 0.20, 0.90, 0.45)
  else
    row('Чат-уведомления:', 'ВЫК', 0.55, 0.55, 0.60)
  end
  row('Платформа:', 'AGLoader ' .. loaderVersion())
  row('Сервер:',    'Arizona (новый движок)')

  imgui.Spacing()
  imgui.Separator()
  imgui.Spacing()
  imgui.BulletText('Скан: id+model всех объектов в заданном радиусе')
  imgui.BulletText('Список: ESP по model ID')
  imgui.BulletText('Линия: стрелка от игрока к объекту')
  imgui.BulletText('Кеш объектов: каждый кадр, позиция игрока живая')
  imgui.Spacing()

  imgui.Separator()
  imgui.Spacing()
  if haveSource() then
    imgui.TextColored('Источник объектов готов', 0.30, 0.90, 0.45, 1)
    row('Смещение позиции', ('+%d'):format(ag.poolPosOffset))
    row('Камера', ('0x%X'):format(ag.cam.addr))
    row('Поле зрения', tostring(ag.cam.fov) .. '°')
  else
    imgui.TextColored('Источник объектов не готов', 1.00, 0.45, 0.30, 1)
    imgui.TextWrapped(
      'Нужны две вещи: смещение позиции в объектах пула и камера. Оба ' ..
      'определяются на живой игре — встаньте от третьего лица, закройте ' ..
      'игровые меню и нажмите кнопку. Игра замрёт на пару секунд.')
    imgui.Spacing()
    imgui.TextWrapped(sourceNote)
  end

  imgui.Spacing()
  imgui.Separator()
  imgui.Spacing()
  imgui.TextColored('Что видит скрипт прямо сейчас', 0.80, 0.82, 0.88, 1)
  row('Пул занят:',  ('%d объектов'):format(diag.pool))
  row('В радиусе:',  ('%d (%d м)'):format(diag.near, renderRadius))
  row('На экране:',  ('%d'):format(diag.onScreen))
  row('Отрисовано:', ('%d'):format(diag.drawn))
  row('Обход пула:', ('%.1f мс'):format(diag.ms))

  -- Ноли в этих строках сразу говорят, где именно всё встало.
  if diag.pool == 0 then
    imgui.TextWrapped('Пул пуст — движок ещё не прогрузил мир либо адрес ' ..
                      'пула не подошёл к этой версии игры.')
  elseif diag.near == 0 then
    imgui.TextWrapped('Объекты есть, но ни один не попал в радиус: скорее ' ..
                      'всего смещение позиции неверное. Нажмите ' ..
                      '«Найти заново».')
  elseif diag.onScreen == 0 then
    imgui.TextWrapped('Объекты рядом есть, но ни один не спроецировался: ' ..
                      'камера найдена неверно либо смотрит не туда. ' ..
                      'Нажмите «Найти заново», стоя от третьего лица.')
  elseif diag.drawn == 0 and not scanMode then
    imgui.TextWrapped('Всё работает, но ни одна модель из списка рядом не ' ..
                      'встретилась. Включите сканер — он подпишет номера ' ..
                      'моделей всех объектов вокруг.')
  end

  imgui.Spacing()
  if imgui.Button(haveSource() and 'Найти заново' or 'Подготовить источник',
                  WIN_W - 70, 44) then
    prepareSource()
  end
end

-- ═════════════════════════════════════════════════════════════ интерфейс

local tab = 1
local TABS = { '  Список  ', '  Цвета  ', '  Info  ' }

function onImgui()
  refreshMetrics()
  ag.beginFrame()
  WIN_W = 480 * MDS

  drawEsp()
  if not winOpen then return end

  pushStyle()

  imgui.SetNextWindowSize(WIN_W, 0, imgui.Cond_Always)
  imgui.SetNextWindowPos((sw - WIN_W) / 2, sh / 2 - 260 * MDS,
                         imgui.Cond_FirstUseEver)

  local visible, open = imgui.Begin('Рендер объектов  v2.4', winOpen,
    imgui.WindowFlags_NoResize + imgui.WindowFlags_NoCollapse +
    imgui.WindowFlags_AlwaysAutoResize)
  winOpen = open

  if visible then
    -- Красная полоса под заголовком.
    local wx, wy = imgui.GetWindowPos()
    local ww = imgui.GetWindowWidth()
    imgui.DrawRectFilled(wx, wy + 32 * MDS, wx + ww, wy + 34 * MDS,
                         0.80, 0.10, 0.10, 1.0)

    -- Блок автора.
    imgui.PushStyleColor(imgui.Col_ChildBg, 0.10, 0.11, 0.15, 1)
    if imgui.BeginChild('##author', WIN_W - 24 * MDS, 54 * MDS, false) then
      imgui.TextDisabled('Автор:')
      imgui.SameLine()
      imgui.TextColored('Victor Strand', 0.95, 0.30, 0.30, 1)

      local tgW = (WIN_W - 24 * MDS - 8 * MDS) / 2
      imgui.PushStyleColor(imgui.Col_Button,        0.10, 0.38, 0.65, 1)
      imgui.PushStyleColor(imgui.Col_ButtonHovered, 0.15, 0.52, 0.85, 1)
      imgui.PushStyleColor(imgui.Col_ButtonActive,  0.07, 0.28, 0.50, 1)
      if imgui.Button('Telegram: @victor_st0', tgW, 22 * MDS) then
        log('https://t.me/victor_st0')
      end
      imgui.SameLine(0, 8 * MDS)
      if imgui.Button('Telegram: @strand_scripts', tgW, 22 * MDS) then
        log('https://t.me/strand_scripts')
      end
      imgui.PopStyleColor(3)
    end
    imgui.EndChild()
    imgui.PopStyleColor()

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- Большая кнопка режима скана.
    local btnW = WIN_W - 24 * MDS
    if scanMode then
      imgui.PushStyleColor(imgui.Col_Button,        0.05, 0.60, 0.20, 1)
      imgui.PushStyleColor(imgui.Col_ButtonHovered, 0.08, 0.75, 0.27, 1)
      imgui.PushStyleColor(imgui.Col_ButtonActive,  0.03, 0.45, 0.15, 1)
      if imgui.Button('[  Сканер ВКЛЮЧЕН  |  ' .. renderRadius ..
                      'м  |  нажми чтобы выкл  ]', btnW, 28 * MDS) then
        scanMode = false
      end
    else
      imgui.PushStyleColor(imgui.Col_Button,        0.15, 0.17, 0.22, 1)
      imgui.PushStyleColor(imgui.Col_ButtonHovered, 0.22, 0.25, 0.32, 1)
      imgui.PushStyleColor(imgui.Col_ButtonActive,  0.10, 0.12, 0.16, 1)
      if imgui.Button('[  Сканер ID (' .. renderRadius ..
                      'м)  |  нажми для вкл  ]', btnW, 28 * MDS) then
        scanMode = true
      end
    end
    imgui.PopStyleColor(3)

    imgui.Spacing()

    -- Вкладки. Свои кнопки вместо TabBar: так они одинаковой ширины и
    -- не расползаются от длины подписи.
    local tw = (WIN_W - 24 * MDS - 2 * 4 * MDS) / 3
    for i, name in ipairs(TABS) do
      if i > 1 then imgui.SameLine(0, 4 * MDS) end
      if i == tab then
        imgui.PushStyleColor(imgui.Col_Button,        0.55, 0.08, 0.08, 1)
        imgui.PushStyleColor(imgui.Col_ButtonHovered, 0.65, 0.10, 0.10, 1)
      else
        imgui.PushStyleColor(imgui.Col_Button,        0.10, 0.10, 0.15, 1)
        imgui.PushStyleColor(imgui.Col_ButtonHovered, 0.65, 0.10, 0.10, 1)
      end
      if imgui.Button(name .. '##tab' .. i, tw, 26 * MDS) then tab = i end
      imgui.PopStyleColor(2)
    end

    imgui.Separator()

    if     tab == 1 then tabList()
    elseif tab == 2 then tabColors()
    else                 tabInfo()
    end
  end

  imgui.End()
  popStyle()
end

-- ═════════════════════════════════════════════════════════════════════ main

function main()
  refreshMetrics()
  loadCfg()

  registerChatCommand('renderob', function()
    winOpen = not winOpen
  end)

  registerChatCommand('robjscan', function()
    scanMode = not scanMode
    log('[RenderObjects] scan: ' .. (scanMode and 'ON' or 'OFF'))
  end)

  log('[RenderObjects v2.4] /renderob')

  -- Пробуем поднять источник сами: если игрок уже в мире, всё найдётся
  -- с первого раза и от пользователя ничего не потребуется.
  lua_thread.create(function()
    for _ = 1, 30 do
      if sourceReady() then break end
      if prepareSource() then
        log('[RenderObjects] источник готов, ESP работает')
        break
      end
      wait(3000)
    end
  end)

  -- Обновление списка объектов, как в оригинале — раз в 500 мс.
  while true do
    if sourceReady() then refreshCache() end
    wait(500)
  end
end

function onScriptTerminate()
  saveCfg()
end
