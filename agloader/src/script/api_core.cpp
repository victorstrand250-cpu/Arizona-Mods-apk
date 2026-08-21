// SPDX-License-Identifier: GPL-3.0-or-later
//
// Базовый API: описание скрипта, ожидание, лог, сведения об окружении.
#include <cstdio>
#include <cstring>
#include <string>

#include "engine.h"
#include <sys/stat.h>
#include <cerrno>
#include "gui.h"
#include "loader.h"
#include "log.h"
#include "lua.hpp"
#include "paths.h"
#include "script/api.h"
#include "script/manager.h"
#include "script/script.h"


namespace ag::script::api {
namespace {

Script* self(lua_State* L)
{
  Script* s = Script::from(L);
  if (s == nullptr) {
    luaL_error(L, "загрузчик: скрипт не привязан к состоянию Lua");
  }
  return s;
}

// Склеивает все аргументы через tostring, как это делает print.
std::string concat_args(lua_State* L, int from)
{
  std::string out;
  const int top = lua_gettop(L);
  for (int i = from; i <= top; ++i) {
    lua_getglobal(L, "tostring");
    lua_pushvalue(L, i);
    if (lua_pcall(L, 1, 1, 0) != 0) {
      lua_pop(L, 1);
      continue;
    }
    std::size_t len = 0;
    const char* s = lua_tolstring(L, -1, &len);
    if (s != nullptr) {
      if (!out.empty()) {
        out.push_back('\t');
      }
      out.append(s, len);
    }
    lua_pop(L, 1);
  }
  return out;
}

// ------------------------------------------------------------ описание

int l_script_name(lua_State* L)
{
  Script* s = self(L);
  s->mutable_info().name = luaL_checkstring(L, 1);
  return 0;
}

int l_script_author(lua_State* L)
{
  Script* s = self(L);
  s->mutable_info().author = luaL_checkstring(L, 1);
  return 0;
}

int l_script_version(lua_State* L)
{
  Script* s = self(L);
  s->mutable_info().version = luaL_checkstring(L, 1);
  return 0;
}

int l_this_script(lua_State* L)
{
  Script* s = self(L);
  const manager::Info& i = s->info();
  lua_newtable(L);
  lua_pushinteger(L, i.id);
  lua_setfield(L, -2, "id");
  lua_pushstring(L, i.name.c_str());
  lua_setfield(L, -2, "name");
  lua_pushstring(L, i.author.c_str());
  lua_setfield(L, -2, "author");
  lua_pushstring(L, i.version.c_str());
  lua_setfield(L, -2, "version");
  lua_pushstring(L, i.file.c_str());
  lua_setfield(L, -2, "filename");
  lua_pushstring(L, i.path.c_str());
  lua_setfield(L, -2, "path");
  return 1;
}

// -------------------------------------------------------------- ожидание

int l_wait(lua_State* L)
{
  const double ms = luaL_optnumber(L, 1, 0.0);
  lua_settop(L, 0);
  lua_pushnumber(L, ms);
  return lua_yield(L, 1);
}

// ------------------------------------------------------------------ лог

int l_log(lua_State* L)
{
  Script* s = Script::from(L);
  const std::string msg = concat_args(L, 1);
  const std::string tag = s != nullptr ? s->info().file : std::string { "?" };
  log::write(log::Level::Script, "agloader", "[%s] %s", tag.c_str(), msg.c_str());
  return 0;
}

int l_print(lua_State* L) { return l_log(L); }

// ------------------------------------------------------------- окружение

// Аналог MONET_DPI_SCALE: явные размеры ImGui не масштабирует, и скрипт,
// рассчитанный на 720p, на телефоне выйдет крошечным.
// ────────────────────────────────────── файловые функции в духе MoonLoader

// Библиотеки вроде inicfg рассчитывают на эти имена и без них не работают.
// Рабочим каталогом считается каталог данных загрузчика.
int l_get_working_directory(lua_State* L)
{
  lua_pushstring(L, paths::root().c_str());
  return 1;
}

int l_does_file_exist(lua_State* L)
{
  const char* path = luaL_checkstring(L, 1);
  struct ::stat st {};
  const bool ok = ::stat(path, &st) == 0 && S_ISREG(st.st_mode);
  lua_pushboolean(L, ok ? 1 : 0);
  return 1;
}

int l_does_directory_exist(lua_State* L)
{
  const char* path = luaL_checkstring(L, 1);
  struct ::stat st {};
  const bool ok = ::stat(path, &st) == 0 && S_ISDIR(st.st_mode);
  lua_pushboolean(L, ok ? 1 : 0);
  return 1;
}

int l_create_directory(lua_State* L)
{
  const char* path = luaL_checkstring(L, 1);
  // Создаём по всей глубине: скрипты часто просят сразу вложенный каталог.
  std::string acc;
  const std::string full { path };
  bool ok = true;
  for (std::size_t i = 0; i <= full.size(); ++i) {
    if (i == full.size() || full[i] == '/') {
      if (acc.size() > 1) {
        if (::mkdir(acc.c_str(), 0775) != 0 && errno != EEXIST) {
          ok = false;
        }
      }
    }
    if (i < full.size()) {
      acc.push_back(full[i]);
    }
  }
  lua_pushboolean(L, ok ? 1 : 0);
  return 1;
}

int l_delete_file(lua_State* L)
{
  const char* path = luaL_checkstring(L, 1);
  lua_pushboolean(L, ::remove(path) == 0 ? 1 : 0);
  return 1;
}

int l_get_ui_scale(lua_State* L)
{
  lua_pushnumber(L, gui::ui_scale());
  return 1;
}

int l_get_screen_size(lua_State* L)
{
  const loader::Screen s = loader::screen();
  lua_pushinteger(L, s.width);
  lua_pushinteger(L, s.height);
  return 2;
}

int l_get_frame_time(lua_State* L)
{
  lua_pushnumber(L, loader::frame_time());
  return 1;
}

int l_get_frame_count(lua_State* L)
{
  lua_pushnumber(L, static_cast<lua_Number>(loader::frame_count()));
  return 1;
}

int l_get_paths(lua_State* L)
{
  lua_newtable(L);
  lua_pushstring(L, paths::root().c_str());
  lua_setfield(L, -2, "root");
  lua_pushstring(L, paths::scripts().c_str());
  lua_setfield(L, -2, "scripts");
  lua_pushstring(L, paths::lua_lib().c_str());
  lua_setfield(L, -2, "lib");
  lua_pushstring(L, paths::config().c_str());
  lua_setfield(L, -2, "config");
  lua_pushstring(L, paths::logs().c_str());
  lua_setfield(L, -2, "logs");
  lua_pushstring(L, paths::package().c_str());
  lua_setfield(L, -2, "package");
  return 1;
}

int l_reload_scripts(lua_State* /*L*/)
{
  manager::request_reload();
  return 0;
}

int l_is_menu_open(lua_State* L)
{
  lua_pushboolean(L, gui::menu_open() ? 1 : 0);
  return 1;
}

int l_set_menu_open(lua_State* L)
{
  gui::set_menu_open(lua_toboolean(L, 1) != 0);
  return 0;
}

// ------------------------------------------------------------------ чат

int l_register_chat_command(lua_State* L)
{
  const char* name = luaL_checkstring(L, 1);
  luaL_checktype(L, 2, LUA_TFUNCTION);
  Script* s = self(L);

  if (name[0] == '/') {
    ++name;  // '/cmd' и 'cmd' — одно и то же
  }
  const std::string key { name };
  if (key.empty()) {
    lua_pushboolean(L, 0);
    return 1;
  }

  lua_pushvalue(L, 2);
  const int ref = luaL_ref(L, LUA_REGISTRYINDEX);
  s->set_command(key, ref);

  log::write(log::Level::Script, "agloader", "[%s] команда /%s",
             s->info().file.c_str(), key.c_str());
  lua_pushboolean(L, 1);
  return 1;
}

int l_unregister_chat_command(lua_State* L)
{
  const char* name = luaL_checkstring(L, 1);
  Script* s = self(L);
  if (name[0] == '/') {
    ++name;
  }
  s->clear_command(name);
  return 0;
}

int l_send_chat(lua_State* L)
{
  const char* text = luaL_checkstring(L, 1);
  lua_pushboolean(L, loader::send_chat(text) ? 1 : 0);
  return 1;
}

int l_can_send_chat(lua_State* L)
{
  lua_pushboolean(L, loader::can_send_chat() ? 1 : 0);
  return 1;
}

int l_loader_version(lua_State* L)
{
  lua_pushstring(L, AGLOADER_VERSION);
  return 1;
}

const luaL_Reg kGlobals[] = {
    { "script_name", l_script_name },
    { "script_author", l_script_author },
    { "script_version", l_script_version },
    { "thisScript", l_this_script },
    { "wait", l_wait },
    { "log", l_log },
    { "print", l_print },
    { "getScreenSize", l_get_screen_size },
    { "getUiScale", l_get_ui_scale },
    { "getWorkingDirectory", l_get_working_directory },
    { "doesFileExist", l_does_file_exist },
    { "doesDirectoryExist", l_does_directory_exist },
    { "createDirectory", l_create_directory },
    { "deleteFile", l_delete_file },
    { "getFrameTime", l_get_frame_time },
    { "getFrameCount", l_get_frame_count },
    { "getPaths", l_get_paths },
    { "reloadScripts", l_reload_scripts },
    { "isMenuOpen", l_is_menu_open },
    { "setMenuOpen", l_set_menu_open },
    { "loaderVersion", l_loader_version },
    { "registerChatCommand", l_register_chat_command },
    { "unregisterChatCommand", l_unregister_chat_command },
    { "sendChat", l_send_chat },
    { "canSendChat", l_can_send_chat },
    { nullptr, nullptr },
};

}  // namespace

void open_core(lua_State* L)
{
  for (const luaL_Reg* r = kGlobals; r->name != nullptr; ++r) {
    lua_pushcfunction(L, r->func);
    lua_setglobal(L, r->name);
  }
}

void open_all(lua_State* L)
{
  open_core(L);
  open_memory(L);
  open_imgui(L);
  open_net(L);
}

}  // namespace ag::script::api
