// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <string>
#include <vector>

namespace ag::script::manager {

enum class State { Loading, Running, Sleeping, Finished, Failed, Terminated };

struct Info {
  int id = 0;
  std::string file;     // имя файла
  std::string path;     // полный путь
  std::string name;     // script_name(...)
  std::string author;   // script_author(...)
  std::string version;  // script_version(...)
  State state = State::Loading;
  std::string error;  // текст последней ошибки
  double cpu_ms = 0.0;  // время последнего кадра
};

// Сканирует каталог scripts/ и создаёт состояния Lua. Движок уже найден.
void init();

// Запускает main() у всех загруженных скриптов. Вызывается из androidInit.
void start();

void shutdown();

// Полная перезагрузка: остановить всё, пересканировать каталог, запустить.
// Безопасно звать из Lua (выполняется отложенно, в начале следующего кадра).
void request_reload();

void on_frame(double dt);
void on_imgui();
bool on_touch(int action, int pointer_id, int x, int y);
bool on_key(int code, int action);

// Строка, отправленная игроком из игрового чата. Возвращает true, если это
// была зарегистрированная команда и передавать её игре не нужно.
// Вызывается с UI-потока, не с потока отрисовки.
bool on_chat_input(const std::string& line);
void on_pause();
void on_resume();

std::vector<Info> list();
void terminate(int id);
void restart(int id);

// Сколько скриптов сейчас живо.
int running_count();

}  // namespace ag::script::manager
