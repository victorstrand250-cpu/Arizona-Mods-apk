-- Исследование памяти прямо в игре.
--
-- Новый движок Arizona собран stripped: символов нет, «правильных» адресов
-- взять неоткуда. Единственный практичный путь — искать по сигнатуре и
-- смотреть, что лежит по найденному адресу. Этот скрипт даёт для этого
-- сканер и hex-просмотрщик, чтобы не выходить из игры.
--
-- Полезно: смещение (второе значение memory.scan) не меняется между
-- запусками, а база libag-client.so меняется из-за ASLR. Записывайте
-- смещения, а адрес считайте как base + offset.

script_name('Memory Explorer')
script_author('agloader')
script_version('1.0')

local show = false
local pattern = '1F 20 03 D5'          -- nop на arm64, просто пример
local module_name = 'libag-client.so'
local match_index = 1
local result_text = 'нажмите «Искать»'

local view_addr = ''
local view_size = 64
local view_text = ''

local base, size = 0, 0

function main()
  base, size = memory.getclientbase()
  if base == 0 then
    log('движок ещё не загружен')
  else
    log(('libag-client.so: 0x%X, %d КБ'):format(base, size / 1024))
  end
  wait(-1)
end

local function do_scan()
  local addr, offset = memory.scan(pattern, module_name, match_index)
  if not addr then
    result_text = 'не найдено: ' .. tostring(offset)
    return
  end
  result_text = ('0x%X   (смещение +0x%X)'):format(addr, offset)
  view_addr = ('0x%X'):format(addr)
  log('scan: ' .. result_text)
end

local function do_view()
  local addr = tonumber(view_addr) or tonumber(view_addr, 16)
  if not addr then
    view_text = 'адрес не разобран'
    return
  end
  local hex, err = memory.hex(addr, view_size)
  if not hex then
    view_text = 'ошибка чтения: ' .. tostring(err)
    return
  end

  -- Разложим по 16 байт в строке.
  local out, n = {}, 0
  local row = {}
  for byte in hex:gmatch('%S+') do
    row[#row + 1] = byte
    if #row == 16 then
      out[#out + 1] = ('%08X  %s'):format(n, table.concat(row, ' '))
      row, n = {}, n + 16
    end
  end
  if #row > 0 then
    out[#out + 1] = ('%08X  %s'):format(n, table.concat(row, ' '))
  end
  view_text = table.concat(out, '\n')
end

function onImgui()
  if not show then
    -- Маленькая кнопка вызова, чтобы не мешать игре.
    imgui.SetNextWindowPos(200, 24, imgui.Cond_FirstUseEver)
    imgui.SetNextWindowSize(150, 60, imgui.Cond_Always)
    local visible = imgui.Begin('##memexp_btn', nil,
      imgui.WindowFlags_NoTitleBar + imgui.WindowFlags_NoResize +
      imgui.WindowFlags_NoScrollbar)
    if visible and imgui.Button('Память', -1, -1) then
      show = true
    end
    imgui.End()
    return
  end

  imgui.SetNextWindowSize(700, 520, imgui.Cond_FirstUseEver)
  local visible, open = imgui.Begin('Memory Explorer', show)
  show = open

  if visible then
    imgui.Text(('база: 0x%X   размер: %d КБ'):format(base, size / 1024))
    imgui.Separator()

    if imgui.BeginTabBar('##tabs') then
      if imgui.BeginTabItem('Поиск') then
        local ch, v = imgui.InputText('сигнатура', pattern, 256)
        if ch then pattern = v end
        ch, v = imgui.InputText('модуль', module_name, 128)
        if ch then module_name = v end
        ch, v = imgui.InputInt('совпадение №', match_index)
        if ch then match_index = math.max(1, v) end

        if imgui.Button('Искать') then do_scan() end
        imgui.SameLine()
        imgui.TextWrapped(result_text)

        imgui.Separator()
        imgui.TextWrapped(
          'Сигнатура — байты через пробел, ?? — любой байт. ' ..
          'Например: FD 7B BF A9 ?? ?? 00 91')
        imgui.EndTabItem()
      end

      if imgui.BeginTabItem('Просмотр') then
        local ch, v = imgui.InputText('адрес', view_addr, 32)
        if ch then view_addr = v end
        ch, v = imgui.InputInt('байт', view_size)
        if ch then view_size = math.min(math.max(v, 16), 1024) end

        if imgui.Button('Читать') then do_view() end
        imgui.Separator()
        if imgui.BeginChild('##hex', 0, 0, true) then
          imgui.Text(view_text)
        end
        imgui.EndChild()
        imgui.EndTabItem()
      end

      if imgui.BeginTabItem('Модули') then
        for _, m in ipairs(memory.getmodules()) do
          if m.name:sub(-3) == '.so' then
            imgui.Text(('%-28s 0x%X  %d КБ'):format(m.name, m.base, m.size / 1024))
          end
        end
        imgui.EndTabItem()
      end

      imgui.EndTabBar()
    end
  end
  imgui.End()
end
