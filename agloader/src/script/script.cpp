// SPDX-License-Identifier: GPL-3.0-or-later
#include "script/script.h"

#include <chrono>
#include <utility>

#include "log.h"
#include "lua.hpp"
#include "paths.h"
#include "script/api.h"

namespace ag::script {
namespace {

constexpr const char* kRegistryKey = "agloader.script";

void set_package_paths(lua_State* L)
{
  const std::string lua_path = paths::scripts() + "/?.lua;" +
                               paths::lua_lib() + "/?.lua;" +
                               paths::lua_lib() + "/?/init.lua";
  const std::string c_path = paths::lua_lib() + "/?.so";

  lua_getglobal(L, "package");
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1);
    return;
  }
  lua_pushlstring(L, lua_path.c_str(), lua_path.size());
  lua_setfield(L, -2, "path");
  lua_pushlstring(L, c_path.c_str(), c_path.size());
  lua_setfield(L, -2, "cpath");
  lua_pop(L, 1);
}

double now_ms()
{
  using clock = std::chrono::steady_clock;
  static const clock::time_point origin = clock::now();
  return std::chrono::duration<double, std::milli>(clock::now() - origin).count();
}

}  // namespace

Script::Script(int id, std::string file, std::string path)
{
  info_.id = id;
  info_.file = std::move(file);
  info_.path = std::move(path);
  info_.name = info_.file;
  info_.state = manager::State::Loading;
}

Script::~Script() { close(); }

Script* Script::from(lua_State* L)
{
  if (L == nullptr) {
    return nullptr;
  }
  lua_getfield(L, LUA_REGISTRYINDEX, kRegistryKey);
  void* p = lua_touserdata(L, -1);
  lua_pop(L, 1);
  return static_cast<Script*>(p);
}

bool Script::is_alive() const
{
  return L_ != nullptr && info_.state != manager::State::Failed &&
         info_.state != manager::State::Terminated;
}

void Script::fail(const std::string& where, const char* lua_error)
{
  info_.state = manager::State::Failed;
  info_.error = where + ": " + (lua_error != nullptr ? lua_error : "?");
  AG_LOGE("[%s] %s", info_.file.c_str(), info_.error.c_str());
}

bool Script::load()
{
  L_ = luaL_newstate();
  if (L_ == nullptr) {
    info_.state = manager::State::Failed;
    info_.error = "не хватило памяти под lua_State";
    return false;
  }

  luaL_openlibs(L_);
  set_package_paths(L_);

  lua_pushlightuserdata(L_, this);
  lua_setfield(L_, LUA_REGISTRYINDEX, kRegistryKey);

  api::open_all(L_);

  if (luaL_loadfile(L_, info_.path.c_str()) != 0) {
    fail("компиляция", lua_tostring(L_, -1));
    lua_pop(L_, 1);
    return false;
  }

  // Верхний уровень файла выполняем сразу: там объявляются script_name(),
  // функции-события и main().
  if (lua_pcall(L_, 0, 0, 0) != 0) {
    fail("выполнение", lua_tostring(L_, -1));
    lua_pop(L_, 1);
    return false;
  }

  info_.state = manager::State::Finished;  // уточнится в start()
  return true;
}

void Script::start()
{
  if (L_ == nullptr || info_.state == manager::State::Failed) {
    return;
  }

  lua_getglobal(L_, "main");
  if (!lua_isfunction(L_, -1)) {
    lua_pop(L_, 1);
    // Скрипт без main() вполне жизнеспособен: он может работать
    // только на событиях onFrame/onImgui.
    info_.state = manager::State::Running;
    main_running_ = false;
    AG_LOGI("[%s] запущен (без main)", info_.file.c_str());
    return;
  }

  thread_ = lua_newthread(L_);          // стек: main, thread
  lua_pushvalue(L_, -1);                // ...thread, thread
  thread_ref_ = luaL_ref(L_, LUA_REGISTRYINDEX);  // держим ссылку от GC
  lua_pop(L_, 1);                       // стек: main
  lua_xmove(L_, thread_, 1);            // переносим main() в корутину

  main_running_ = true;
  info_.state = manager::State::Running;
  wake_at_ = 0.0;
  AG_LOGI("[%s] запущен", info_.file.c_str());
}

void Script::sleep_for(double ms, double from_ms)
{
  if (ms < 0.0) {
    // Как в MoonLoader: wait(-1) усыпляет main() навсегда — скрипт дальше
    // живёт только на событиях.
    wake_at_ = 1.0e18;
    return;
  }
  wake_at_ = from_ms + ms;
}

void Script::tick(double now, double dt)
{
  if (!is_alive()) {
    return;
  }

  const double t0 = now_ms();

  // 1. Корутина main()
  if (main_running_ && thread_ != nullptr && now >= wake_at_) {
    info_.state = manager::State::Running;
    const int rc = lua_resume(thread_, 0);
    if (rc == LUA_YIELD) {
      // wait() кладёт на стек число миллисекунд.
      double ms = 0.0;
      if (lua_gettop(thread_) >= 1 && lua_isnumber(thread_, -1)) {
        ms = lua_tonumber(thread_, -1);
      }
      lua_settop(thread_, 0);
      sleep_for(ms, now);
      info_.state = manager::State::Sleeping;
    } else if (rc == 0) {
      main_running_ = false;
      info_.state = manager::State::Finished;
      AG_LOGI("[%s] main() завершился", info_.file.c_str());
    } else {
      fail("main()", lua_tostring(thread_, -1));
      main_running_ = false;
      info_.cpu_ms = now_ms() - t0;
      return;
    }
  }

  // 2. Событие onFrame(dt)
  if (push_event("onFrame")) {
    lua_pushnumber(L_, dt);
    run_protected(1, 0, "onFrame");
  }

  info_.cpu_ms = now_ms() - t0;
}

bool Script::push_event(const char* name)
{
  if (!is_alive()) {
    return false;
  }
  lua_getglobal(L_, name);
  if (!lua_isfunction(L_, -1)) {
    lua_pop(L_, 1);
    return false;
  }
  return true;
}

void Script::run_protected(int nargs, int nresults, const char* where)
{
  if (lua_pcall(L_, nargs, nresults, 0) != 0) {
    fail(where, lua_tostring(L_, -1));
    lua_pop(L_, 1);
  }
}

void Script::call_event_void(const char* name)
{
  if (!push_event(name)) {
    return;
  }
  run_protected(0, 0, name);
}

bool Script::call_event_consumable(const char* name, int a, int b, int c, int d,
                                   int argc)
{
  if (!push_event(name)) {
    return false;
  }

  const int args[4] = { a, b, c, d };
  for (int i = 0; i < argc && i < 4; ++i) {
    lua_pushinteger(L_, args[i]);
  }

  if (lua_pcall(L_, argc, 1, 0) != 0) {
    fail(name, lua_tostring(L_, -1));
    lua_pop(L_, 1);
    return false;
  }

  // Как в MoonLoader/MonetLoader: явный false означает «событие поглощено».
  const bool consumed = lua_isboolean(L_, -1) && lua_toboolean(L_, -1) == 0;
  lua_pop(L_, 1);
  return consumed;
}

void Script::call_terminate()
{
  if (!is_alive()) {
    return;
  }
  call_event_void("onScriptTerminate");
}

void Script::stop()
{
  main_running_ = false;
  if (info_.state != manager::State::Failed) {
    info_.state = manager::State::Terminated;
  }
  AG_LOGI("[%s] остановлен", info_.file.c_str());
}

void Script::close()
{
  if (L_ == nullptr) {
    return;
  }
  if (thread_ref_ != -1) {
    luaL_unref(L_, LUA_REGISTRYINDEX, thread_ref_);
    thread_ref_ = -1;
  }
  thread_ = nullptr;
  main_running_ = false;
  lua_close(L_);
  L_ = nullptr;
}

}  // namespace ag::script
