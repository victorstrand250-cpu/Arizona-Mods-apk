// SPDX-License-Identifier: GPL-3.0-or-later
#include "script/script.h"

#include <algorithm>
#include <chrono>
#include <utility>

#include "log.h"
#include "lua.hpp"
#include "paths.h"
#include "script/api.h"
#include "script/prelude.h"

// Нативные модули для скриптов. Собраны прямо в загрузчик (см. CMakeLists,
// цель luamods) и подставляются в package.preload вместо отдельных .so:
// каталог Android/media примонтирован без права выполнения, dlopen оттуда
// невозможен в принципе.
extern "C" {
int luaopen_cjson(lua_State* L);
int luaopen_cjson_safe(lua_State* L);
int luaopen_lfs(lua_State* L);
int luaopen_socket_core(lua_State* L);
int luaopen_mime_core(lua_State* L);
}

namespace ag::script {
namespace {

// require('имя') для модуля, который уже внутри библиотеки.
void preload(lua_State* L, const char* name, lua_CFunction fn)
{
  lua_getfield(L, LUA_GLOBALSINDEX, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, fn);
  lua_setfield(L, -2, name);
  lua_pop(L, 2);
}

void open_native_modules(lua_State* L)
{
  preload(L, "cjson", luaopen_cjson);
  preload(L, "cjson.safe", luaopen_cjson_safe);
  preload(L, "lfs", luaopen_lfs);
  preload(L, "socket.core", luaopen_socket_core);
  preload(L, "mime.core", luaopen_mime_core);
}


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

namespace {

// Ставится обработчиком ошибки в lua_pcall: к тексту ошибки дописывает стек
// вызовов, иначе от упавшего скрипта остаётся только 'attempt to index nil'
// без единого намёка, где именно.
int traceback_handler(lua_State* L)
{
  const char* msg = lua_tostring(L, 1);
  if (msg == nullptr) {
    msg = "(ошибка без текста)";
  }

  lua_getglobal(L, "debug");
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1);
    lua_pushstring(L, msg);
    return 1;
  }
  lua_getfield(L, -1, "traceback");
  if (!lua_isfunction(L, -1)) {
    lua_pop(L, 2);
    lua_pushstring(L, msg);
    return 1;
  }

  lua_pushstring(L, msg);
  lua_pushinteger(L, 2);  // пропустить сам обработчик
  if (lua_pcall(L, 2, 1, 0) != 0) {
    lua_pop(L, 1);
    lua_pushstring(L, msg);
  }
  return 1;
}

// Стек корутины живёт отдельно от основного состояния, поэтому для main()
// трейс приходится собирать через debug.traceback(thread, msg).
std::string thread_traceback(lua_State* L, lua_State* thread, const char* msg)
{
  std::string out { msg != nullptr ? msg : "(ошибка без текста)" };

  lua_getglobal(L, "debug");
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1);
    return out;
  }
  lua_getfield(L, -1, "traceback");
  if (!lua_isfunction(L, -1)) {
    lua_pop(L, 2);
    return out;
  }

  lua_pushthread(thread);
  lua_xmove(thread, L, 1);
  lua_pushstring(L, out.c_str());
  if (lua_pcall(L, 2, 1, 0) == 0) {
    const char* full = lua_tostring(L, -1);
    if (full != nullptr) {
      out = full;
    }
  }
  lua_pop(L, 2);  // результат (или ошибка) + таблица debug
  return out;
}

}  // namespace

void Script::fail(const std::string& where, const char* lua_error)
{
  info_.state = manager::State::Failed;
  info_.error = where + ": " + (lua_error != nullptr ? lua_error : "?");

  // Многострочный трейс режем на строки: в logcat одна строка на запись
  // читается, а слипшийся в одну кусок — нет.
  AG_LOGE("[%s] ОСТАНОВЛЕН ОШИБКОЙ в %s", info_.file.c_str(), where.c_str());
  const std::string text { lua_error != nullptr ? lua_error : "?" };
  std::size_t from = 0;
  while (from <= text.size()) {
    std::size_t nl = text.find('\n', from);
    if (nl == std::string::npos) {
      nl = text.size();
    }
    if (nl > from) {
      AG_LOGE("           %s", text.substr(from, nl - from).c_str());
    }
    from = nl + 1;
  }
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
  open_native_modules(L_);

  lua_pushlightuserdata(L_, this);
  lua_setfield(L_, LUA_REGISTRYINDEX, kRegistryKey);

  api::open_all(L_);

  // Пролог до кода скрипта: даёт lua_thread и привычные имена MoonLoader.
  if (luaL_loadstring(L_, prelude_source()) != 0 ||
      lua_pcall(L_, 0, 0, 0) != 0) {
    fail("пролог", lua_tostring(L_, -1));
    lua_pop(L_, 1);
    return false;
  }

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
      const std::string trace =
          thread_traceback(L_, thread_, lua_tostring(thread_, -1));
      fail("main()", trace.c_str());
      main_running_ = false;
      info_.cpu_ms = now_ms() - t0;
      return;
    }
  }

  // 2. Фоновые корутины lua_thread — их крутит планировщик из пролога.
  if (push_event("__agloader_tick")) {
    lua_pushnumber(L_, dt);
    run_protected(1, 0, "lua_thread");
  }

  // 3. Событие onFrame(dt)
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
  // Обработчик кладём под вызываемую функцию: pcall ждёт его индекс в стеке.
  const int base = lua_gettop(L_) - nargs;
  lua_pushcfunction(L_, traceback_handler);
  lua_insert(L_, base);

  const int rc = lua_pcall(L_, nargs, nresults, base);
  lua_remove(L_, base);

  if (rc != 0) {
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

void Script::set_command(const std::string& name, int lua_ref)
{
  clear_command(name);
  commands_[name] = lua_ref;
}

void Script::clear_command(const std::string& name)
{
  auto it = commands_.find(name);
  if (it == commands_.end()) {
    return;
  }
  if (L_ != nullptr) {
    luaL_unref(L_, LUA_REGISTRYINDEX, it->second);
  }
  commands_.erase(it);
}

std::vector<std::string> Script::command_names() const
{
  std::vector<std::string> out;
  out.reserve(commands_.size());
  for (const auto& kv : commands_) {
    out.push_back(kv.first);
  }
  std::sort(out.begin(), out.end());
  return out;
}

bool Script::call_command(const std::string& name, const std::string& args)
{
  if (!is_alive()) {
    return false;
  }
  auto it = commands_.find(name);
  if (it == commands_.end()) {
    return false;
  }

  lua_rawgeti(L_, LUA_REGISTRYINDEX, it->second);
  if (!lua_isfunction(L_, -1)) {
    lua_pop(L_, 1);
    return false;
  }
  lua_pushlstring(L_, args.c_str(), args.size());
  run_protected(1, 0, ("команда /" + name).c_str());
  return true;
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
  for (auto& kv : commands_) {
    luaL_unref(L_, LUA_REGISTRYINDEX, kv.second);
  }
  commands_.clear();
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
