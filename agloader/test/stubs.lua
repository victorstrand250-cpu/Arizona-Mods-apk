-- Заглушки загрузчика: столько, чтобы скрипт дожил до конца кадра
-- на обычном lua5.1, без игры и без телефона.
local root = os.getenv('AGL_ROOT') or '.'
package.path = root .. '/lib/?.lua;' .. root .. '/lib/?/init.lua;' .. package.path
local cfgdir = os.getenv('AGL_CFG') or '/tmp/aglcfg'
os.execute('mkdir -p "' .. cfgdir .. '"')
function log(...) local p={} for i=1,select('#',...) do p[#p+1]=tostring(select(i,...)) end io.write(table.concat(p,'\t'),'\n') end
function getPaths()
  return { scripts = root .. '/scripts', config = cfgdir,
           lib = root .. '/lib', root = root, logs = cfgdir }
end
function getWorkingDirectory() return '/tmp/agl' end
function getScreenSize() return 1280, 720 end
function getUiScale() return 1.0 end
function loaderVersion() return '0.1.0' end
function doesDirectoryExist(p) return os.execute('test -d "'..p..'"') == 0 end
function doesFileExist(p) local f=io.open(p) if f then f:close() return true end return false end
function createDirectory(p) os.execute('mkdir -p "'..p..'"') return true end
function deleteFile(p) os.remove(p) return true end
function getFrameTime() return 0.016 end
function getFrameCount() return 1 end
function thisScript() return { id=1, name='t', author='a', version='1', filename='t.lua', path='./scripts/t.lua' } end
cmds = {}
function registerChatCommand(n, f) cmds[n]=f end
function unregisterChatCommand(n) cmds[n]=nil end
function sendChat() end
function canSendChat() return true end
function isMenuOpen() return false end
function setMenuOpen() end
function reloadScripts() end
function wait() end
function script_name() end
function script_author() end
function script_version() end
function script_description() end
function script_dependencies() end
function script_url() end
function script_properties() end
lua_thread = { create = function(f) return { fn = f } end, create_suspended = function(f) return { fn = f } end }
memory = setmetatable({
  getclientbase = function() return 0 end,
  readbytes = function() return nil end,
  readptrs = function() return {}, {} end,
  gather = function() return {}, {} end,
  regions = function() return {} end,
  readu16=function() return nil end, readu8=function() return nil end,
  readu32=function() return nil end,
  readfloat=function() return nil end, deref=function() return nil end,
  readmatrix=function() return nil end, findmatrix=function() return nil,'нет' end,
  findvalue=function() return {},0,false end, refine=function() return {},0,false end,
  inspect=function() return {} end, readpositions=function() return {},0 end,
  findpointerto=function() return {},0 end, hex=function() return '' end,
  read=function() return nil end, write=function() return false end,
  readstring=function() return nil end, isvalid=function() return false end,
  getmodules=function() return {} end, getmodulebase=function() return 0 end,
}, { __index = function(_, k) return function() return nil end end })
net = setmetatable({}, { __index = function() return function() return nil end end })
imgui = setmetatable({}, { __index = function(t, k)
  if k:match('^Col_') or k:match('^StyleVar_') or k:match('^Cond_')
     or k:match('^WindowFlags_') or k:match('^ColorEditFlags_') then return 1 end
  if k == 'Begin' or k == 'BeginChild' or k == 'BeginTabItem'
     or k == 'BeginTabBar' or k == 'CollapsingHeader' then
    return function() return true, true end
  end
  if k:match('^Get') or k:match('^Calc') then
    return function() return 100, 100 end
  end
  if k == 'ColorEdit4' then return function() return false,1,1,1,1 end end
  if k == 'SliderInt' or k == 'SliderFloat' or k == 'InputInt'
     or k == 'InputText' or k == 'Checkbox' or k == 'Combo' then
    return function(_, cur) return false, cur end
  end
  return function() return false end
end })

return { cmds = cmds, root = root }
