-- ESP по игрокам: метки над всеми, кого движок держит в массиве слотов.
--
--   /pesp     показать или убрать метки
--   /pespmenu настройки
--
-- Проверяет сразу три вещи: массив игроков, пакетное чтение полей и
-- проекцию камеры. Если метки стоят ровно на людях — найденные адреса верны.

script_name('PlayerESP')
script_author('AGLoader')
script_version('1.0')

local ag = require 'arizona'

local espOn    = false
local menuOpen = false
local radius   = 300
local showLine = false
local showDist = true
local showSlot = true
local showNick = true

local MDS, sw, sh = 1, 1280, 720
local cache, lastRefresh = {}, 0

local cfgPath = getPaths().config .. '/playeresp.ini'

local function saveCfg()
  local f = io.open(cfgPath, 'w')
  if not f then return end
  f:write(('radius=%d\nline=%s\ndist=%s\nslot=%s\nnick=%s\non=%s\n')
    :format(radius, tostring(showLine), tostring(showDist),
            tostring(showSlot), tostring(showNick), tostring(espOn)))
  f:close()
end

local function loadCfg()
  local f = io.open(cfgPath, 'r')
  if not f then return end
  for line in f:lines() do
    local k, v = line:match('^(%w+)=(.*)$')
    if     k == 'radius' then radius = tonumber(v) or radius
    elseif k == 'line'   then showLine = (v == 'true')
    elseif k == 'dist'   then showDist = (v == 'true')
    elseif k == 'slot'   then showSlot = (v == 'true')
    elseif k == 'nick'   then showNick = (v == 'true')
    elseif k == 'on'     then espOn = (v == 'true') end
  end
  f:close()
end

-- ═══════════════════════════════════════════════════════════ отрисовка

local function refresh()
  cache = {}
  local me = ag.localPlayer()
  if not me then return end
  local px, py, pz = ag.position(me)
  if not px then return end

  for _, p in ipairs(ag.players({ skipLocal = true })) do
    local d = getDistanceBetweenCoords3d(px, py, pz, p.x, p.y, p.z)
    if d <= radius then
      p.dist = d
      p.nick = showNick and ag.nick(p.index) or nil
      cache[#cache + 1] = p
    end
  end
  table.sort(cache, function(a, b) return a.dist < b.dist end)
end

function onImgui()
  local s = getUiScale()
  if s and s > 0 then MDS = s end
  local w, h = getScreenSize()
  if w and w > 0 then sw, sh = w, h end

  if espOn then
    local cam = ag.cameraMatrix()
    if cam then
      local me = ag.localPlayer()
      local ax, ay = sw / 2, sh - 40 * MDS
      if me then
        local mx, my, mz = ag.position(me)
        if mx then
          local bx, by = ag.worldToScreen(mx, my, mz, sw, sh, cam)
          if bx then ax, ay = bx, by end
        end
      end

      for _, p in ipairs(cache) do
        -- Метка ставится на голову, а не в центр: +1 метр по высоте.
        local sx, sy = ag.worldToScreen(p.x, p.y, p.z + 1.0, sw, sh, cam)
        if sx and sx > -100 and sx < sw + 100 and sy > -100 and sy < sh + 100 then
          local label = p.nick or (showSlot and ('слот ' .. p.index) or '')
          if showSlot and p.nick then
            label = label .. ' [' .. p.index .. ']'
          end
          if showDist then
            label = label .. ('  %.0fм'):format(p.dist)
          end
          if p.inVehicle then label = label .. '  (в тачке)' end

          -- Тень, чтобы читалось на светлом фоне.
          imgui.DrawText(sx + 1, sy + 1, label, 0, 0, 0, 0.7)
          local r, g, b = 0.30, 0.90, 0.45
          if p.inVehicle then r, g, b = 0.35, 0.70, 1.00 end
          imgui.DrawText(sx, sy, label, r, g, b, 1)
          imgui.DrawCircleFilled(sx - 5 * MDS, sy + 6 * MDS, 3 * MDS, r, g, b, 1)

          if showLine then
            imgui.DrawLine(ax, ay, sx, sy, r, g, b, 0.45, 1.5)
          end
        end
      end
    end
  end

  if not menuOpen then return end

  imgui.SetNextWindowSize(360 * MDS, 0, imgui.Cond_Always)
  local visible, open = imgui.Begin('PlayerESP', menuOpen,
    imgui.WindowFlags_NoResize + imgui.WindowFlags_AlwaysAutoResize)
  menuOpen = open

  if visible then
    local ch, v = imgui.Checkbox('Метки включены', espOn)
    if ch then espOn = v; saveCfg() end

    imgui.SetNextItemWidth(200 * MDS)
    ch, v = imgui.SliderInt('Радиус', radius, 20, 1000, radius .. ' м')
    if ch then radius = v; saveCfg() end

    ch, v = imgui.Checkbox('Ник', showNick)
    if ch then showNick = v; saveCfg() end
    imgui.SameLine()
    ch, v = imgui.Checkbox('Слот', showSlot)
    if ch then showSlot = v; saveCfg() end
    imgui.SameLine()
    ch, v = imgui.Checkbox('Дистанция', showDist)
    if ch then showDist = v; saveCfg() end

    ch, v = imgui.Checkbox('Линии от игрока', showLine)
    if ch then showLine = v; saveCfg() end

    imgui.Separator()
    imgui.Text(('Видно игроков: %d'):format(#cache))
    if ag.cam.addr == 0 then
      imgui.TextColored('Камера не найдена — откройте /recon и нажмите ' ..
                        '«Найти камеру»', 1.0, 0.45, 0.30, 1)
    else
      imgui.TextDisabled(('камера 0x%X, поле зрения %d°')
                         :format(ag.cam.addr, ag.cam.fov))
    end
    if not ag.nickOffset then
      imgui.TextDisabled('Ник не подключён: /recon → «Слот» → найти ник')
    end

    imgui.Separator()
    if imgui.Button('Ближайшие', 340 * MDS, 0) then
      for i = 1, math.min(#cache, 10) do
        local p = cache[i]
        log(('[PlayerESP] %s слот %d  %.0fм  %.1f %.1f %.1f')
            :format(p.nick or '-', p.index, p.dist, p.x, p.y, p.z))
      end
    end
  end
  imgui.End()
end

-- ═════════════════════════════════════════════════════════════════ main

function main()
  loadCfg()
  ag.loadProjection()

  registerChatCommand('pesp', function()
    espOn = not espOn
    saveCfg()
    log('[PlayerESP] метки ' .. (espOn and 'включены' or 'выключены'))
  end)

  registerChatCommand('pespmenu', function() menuOpen = not menuOpen end)

  log('[PlayerESP] /pesp — метки, /pespmenu — настройки')

  while true do
    if espOn or menuOpen then refresh() end
    wait(250)
  end
end

function onScriptTerminate()
  saveCfg()
end
