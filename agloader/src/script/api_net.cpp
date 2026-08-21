// SPDX-License-Identifier: GPL-3.0-or-later
//
// Сетевой слой для Lua. Наружу отдаётся только асинхронная часть: запустить
// запрос и опрашивать состояние. Всё привычное поверх этого — requests.get,
// socket.http.request и прочее — собрано на Lua в lib/, чтобы блокирующий
// вид вызова не означал блокировку потока отрисовки.
#include <string>

#include "log.h"
#include "lua.hpp"
#include "net.h"
#include "script/api.h"

namespace ag::script::api {
namespace {

// Читает таблицу заголовков { ['Content-Type'] = 'application/json' }.
void read_headers(lua_State* L, int index, std::map<std::string, std::string>* out)
{
  if (!lua_istable(L, index)) {
    return;
  }
  lua_pushnil(L);
  while (lua_next(L, index) != 0) {
    if (lua_isstring(L, -2) && lua_isstring(L, -1)) {
      (*out)[lua_tostring(L, -2)] = lua_tostring(L, -1);
    }
    lua_pop(L, 1);
  }
}

// net.start{ url =, method =, body =, headers =, timeout = } -> номер
int l_start(lua_State* L)
{
  luaL_checktype(L, 1, LUA_TTABLE);
  net::Request req;

  lua_getfield(L, 1, "url");
  if (lua_isstring(L, -1)) {
    req.url = lua_tostring(L, -1);
  }
  lua_pop(L, 1);

  if (req.url.empty()) {
    lua_pushnil(L);
    lua_pushstring(L, "не задан адрес");
    return 2;
  }

  lua_getfield(L, 1, "method");
  if (lua_isstring(L, -1)) {
    req.method = lua_tostring(L, -1);
  }
  lua_pop(L, 1);

  lua_getfield(L, 1, "body");
  if (lua_isstring(L, -1)) {
    std::size_t len = 0;
    const char* p = lua_tolstring(L, -1, &len);
    req.body.assign(p, len);
  }
  lua_pop(L, 1);

  lua_getfield(L, 1, "timeout");
  if (lua_isnumber(L, -1)) {
    req.timeout_ms = static_cast<int>(lua_tonumber(L, -1));
  }
  lua_pop(L, 1);

  lua_getfield(L, 1, "headers");
  read_headers(L, lua_gettop(L), &req.headers);
  lua_pop(L, 1);

  const int id = net::start(req);
  if (id == 0) {
    lua_pushnil(L);
    lua_pushstring(L, "не удалось начать запрос");
    return 2;
  }
  lua_pushnumber(L, id);
  return 1;
}

// net.poll(номер) -> 'running' | 'done' | 'failed'
int l_poll(lua_State* L)
{
  const int id = static_cast<int>(luaL_checknumber(L, 1));
  switch (net::poll(id)) {
    case net::State::Running: lua_pushstring(L, "running"); break;
    case net::State::Done:    lua_pushstring(L, "done"); break;
    default:                  lua_pushstring(L, "failed"); break;
  }
  return 1;
}

// net.result(номер) -> таблица с кодом, телом и заголовками
int l_result(lua_State* L)
{
  const int id = static_cast<int>(luaL_checknumber(L, 1));
  net::Response resp;
  if (!net::take(id, &resp)) {
    lua_pushnil(L);
    lua_pushstring(L, "запрос ещё не завершён");
    return 2;
  }

  lua_newtable(L);
  lua_pushnumber(L, resp.code);
  lua_setfield(L, -2, "code");
  lua_pushlstring(L, resp.body.data(), resp.body.size());
  lua_setfield(L, -2, "body");
  lua_pushboolean(L, resp.state == net::State::Done ? 1 : 0);
  lua_setfield(L, -2, "ok");
  if (!resp.error.empty()) {
    lua_pushstring(L, resp.error.c_str());
    lua_setfield(L, -2, "error");
  }

  lua_newtable(L);
  for (const auto& kv : resp.headers) {
    lua_pushstring(L, kv.second.c_str());
    lua_setfield(L, -2, kv.first.c_str());
  }
  lua_setfield(L, -2, "headers");
  return 1;
}

int l_release(lua_State* L)
{
  net::release(static_cast<int>(luaL_checknumber(L, 1)));
  return 0;
}

int l_pending(lua_State* L)
{
  lua_pushnumber(L, static_cast<lua_Number>(net::pending()));
  return 1;
}

const luaL_Reg kNet[] = {
    { "start", l_start },
    { "poll", l_poll },
    { "result", l_result },
    { "release", l_release },
    { "pending", l_pending },
    { nullptr, nullptr },
};

}  // namespace

void open_net(lua_State* L)
{
  lua_newtable(L);
  for (const luaL_Reg* r = kNet; r->name != nullptr; ++r) {
    lua_pushcfunction(L, r->func);
    lua_setfield(L, -2, r->name);
  }
  lua_setglobal(L, "net");
}

}  // namespace ag::script::api
