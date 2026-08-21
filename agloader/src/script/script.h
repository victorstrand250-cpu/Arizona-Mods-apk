// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <string>
#include <unordered_map>
#include <vector>

#include "script/manager.h"

struct lua_State;

namespace ag::script {

// Один .lua-файл со своим lua_State. Состояния изолированы: упавший скрипт
// не утаскивает за собой остальные и тем более игру.
class Script {
 public:
  Script(int id, std::string file, std::string path);
  ~Script();

  Script(const Script&) = delete;
  Script& operator=(const Script&) = delete;

  // Создаёт lua_State, открывает библиотеки и компилирует файл.
  bool load();

  // Запускает main() в отдельной корутине, если он есть.
  void start();

  // Один кадр: пробуждает корутину и вызывает onFrame.
  void tick(double now_ms, double dt);

  void call_event_void(const char* name);

  // Вызывает событие с argc целочисленными аргументами.
  // Возвращает true, если скрипт вернул false (то есть поглотил событие).
  bool call_event_consumable(const char* name, int a, int b, int c, int d,
                             int argc = 4);

  void call_terminate();

  // Регистрация чат-команды. Функция берётся с вершины стека Lua.
  void set_command(const std::string& name, int lua_ref);
  void clear_command(const std::string& name);

  // Если команда зарегистрирована — вызывает её и возвращает true.
  bool call_command(const std::string& name, const std::string& args);

  // Какие чат-команды зарегистрировал скрипт. Нужно, чтобы показать их
  // пользователю: иначе он не знает, что вообще набирать.
  std::vector<std::string> command_names() const;

  // Сколько касаний скрипт уже поглотил и предупреждали ли о нём. Лежит
  // на виду, а не в приватной части: считает менеджер, ему же и решать.
  int touches_eaten = 0;
  bool touch_warned = false;


  // Помечает скрипт остановленным, но lua_State оставляет живым
  // (например, чтобы показать текст ошибки в меню).
  void stop();

  void close();

  const manager::Info& info() const { return info_; }
  manager::Info& mutable_info() { return info_; }

  lua_State* state() const { return L_; }

  // Вызывается из wait(): усыпить корутину на ms миллисекунд.
  void sleep_for(double ms, double now_ms);

  // Достаёт Script* из реестра состояния. nullptr, если состояние чужое.
  static Script* from(lua_State* L);

 private:
  bool is_alive() const;
  void fail(const std::string& where, const char* lua_error);
  bool push_event(const char* name);
  void run_protected(int nargs, int nresults, const char* where);

  manager::Info info_;
  lua_State* L_ = nullptr;
  lua_State* thread_ = nullptr;
  int thread_ref_ = -1;
  bool main_running_ = false;
  double wake_at_ = 0.0;

  // имя команды -> ссылка на функцию в реестре Lua
  std::unordered_map<std::string, int> commands_;
};

}  // namespace ag::script
