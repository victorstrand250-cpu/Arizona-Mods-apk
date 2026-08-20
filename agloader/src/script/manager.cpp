// SPDX-License-Identifier: GPL-3.0-or-later
#include "script/manager.h"

#include <dirent.h>
#include <sys/stat.h>

#include <algorithm>
#include <cstddef>
#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "gui.h"
#include "lua.hpp"
#include "log.h"
#include "paths.h"
#include "script/api.h"
#include "script/script.h"

namespace ag::script::manager {
namespace {

std::mutex g_lock;
std::vector<std::unique_ptr<Script>> g_scripts;
int g_next_id = 1;
// Атомик, а не поле под g_lock: request_reload() вызывается из Lua, то есть
// изнутри on_frame, который этот мьютекс уже держит. Захват здесь означал бы
// мгновенный дедлок и зависшую игру.
std::atomic<bool> g_reload_requested { false };
bool g_started = false;
bool g_inited = false;

double now_ms()
{
  using clock = std::chrono::steady_clock;
  static const clock::time_point origin = clock::now();
  return std::chrono::duration<double, std::milli>(clock::now() - origin).count();
}

std::vector<std::string> list_lua_files(const std::string& dir)
{
  std::vector<std::string> out;
  DIR* d = ::opendir(dir.c_str());
  if (d == nullptr) {
    return out;
  }
  while (dirent* e = ::readdir(d)) {
    std::string name { e->d_name };
    if (name.size() < 5 || name.compare(name.size() - 4, 4, ".lua") != 0) {
      continue;
    }
    if (name[0] == '.') {
      continue;  // скрытые и «отключённые» файлы пропускаем
    }
    struct stat st {};
    const std::string full = dir + "/" + name;
    if (::stat(full.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) {
      continue;
    }
    out.push_back(name);
  }
  ::closedir(d);
  std::sort(out.begin(), out.end());
  return out;
}

void destroy_all()
{
  for (auto& s : g_scripts) {
    s->call_terminate();
    s->close();
  }
  g_scripts.clear();
}

void scan_and_load()
{
  const auto files = list_lua_files(paths::scripts());
  AG_LOGI("каталог скриптов: %s", paths::scripts().c_str());
  if (files.empty()) {
    AG_LOGW("скриптов не найдено — положите .lua в этот каталог");
    return;
  }
  AG_LOGI("найдено файлов: %zu, загружаю", files.size());

  std::size_t ok = 0;
  std::size_t failed = 0;
  const std::size_t total = files.size();

  for (std::size_t i = 0; i < total; ++i) {
    const std::string& file = files[i];
    auto s = std::make_unique<Script>(g_next_id++, file,
                                      paths::scripts() + "/" + file);
    const bool loaded = s->load();
    const auto& in = s->info();

    if (loaded) {
      ++ok;
      // script_name/author/version объявляются на верхнем уровне файла,
      // то есть к этому моменту уже известны.
      AG_LOGI("  [%zu/%zu] %s — \"%s\" %s, автор: %s", i + 1, total,
              file.c_str(),
              in.name.empty() ? "без имени" : in.name.c_str(),
              in.version.empty() ? "?" : in.version.c_str(),
              in.author.empty() ? "?" : in.author.c_str());
    } else {
      ++failed;
      AG_LOGE("  [%zu/%zu] %s — НЕ ЗАГРУЖЕН", i + 1, total, file.c_str());
      AG_LOGE("           причина: %s", in.error.c_str());
    }
    g_scripts.push_back(std::move(s));
  }

  if (failed == 0) {
    AG_LOGI("загружено скриптов: %zu из %zu", ok, total);
  } else {
    AG_LOGE("загружено скриптов: %zu из %zu, с ошибками: %zu", ok, total, failed);
  }
}

void do_reload()
{
  AG_LOGI("перезагрузка скриптов");
  destroy_all();
  scan_and_load();
  for (auto& s : g_scripts) {
    s->start();
  }
}

}  // namespace

void init()
{
  std::lock_guard<std::mutex> guard { g_lock };
  if (g_inited) {
    return;
  }
  g_inited = true;
  scan_and_load();
  if (g_started) {
    // start() успел отработать до того, как скрипты были прочитаны, —
    // запускаем их здесь.
    for (auto& s : g_scripts) {
      s->start();
    }
  }
}

void start()
{
  std::lock_guard<std::mutex> guard { g_lock };
  if (g_started) {
    return;
  }
  g_started = true;
  if (!g_inited) {
    return;  // init() ещё не отработал и запустит скрипты сам
  }
  for (auto& s : g_scripts) {
    s->start();
  }
}

void shutdown()
{
  std::lock_guard<std::mutex> guard { g_lock };
  destroy_all();
  g_inited = false;
  g_started = false;
}

void request_reload() { g_reload_requested.store(true); }

void on_frame(double dt)
{
  std::lock_guard<std::mutex> guard { g_lock };

  if (g_reload_requested.exchange(false)) {
    do_reload();
  }

  const double t = now_ms();
  for (auto& s : g_scripts) {
    s->tick(t, dt);
  }
}

void on_imgui()
{
  std::lock_guard<std::mutex> guard { g_lock };
  api::imgui_set_frame_active(true);
  for (auto& s : g_scripts) {
    s->call_event_void("onImgui");
    api::imgui_unwind();
  }
  api::imgui_set_frame_active(false);
}

bool on_touch(int action, int pointer_id, int x, int y)
{
  std::lock_guard<std::mutex> guard { g_lock };
  bool consumed = false;
  for (auto& s : g_scripts) {
    if (s->call_event_consumable("onTouch", action, pointer_id, x, y)) {
      consumed = true;
    }
  }
  return consumed;
}

bool on_key(int code, int action)
{
  std::lock_guard<std::mutex> guard { g_lock };
  bool consumed = false;
  for (auto& s : g_scripts) {
    if (s->call_event_consumable("onKey", code, action, 0, 0, 2)) {
      consumed = true;
    }
  }
  return consumed;
}

bool on_chat_input(const std::string& line)
{
  if (line.empty() || line[0] != '/') {
    return false;
  }

  // '/имя аргументы' -> имя, аргументы
  std::size_t end = line.find(' ');
  if (end == std::string::npos) {
    end = line.size();
  }
  const std::string name = line.substr(1, end - 1);
  if (name.empty()) {
    return false;
  }
  std::string args;
  if (end < line.size()) {
    args = line.substr(end + 1);
  }

  {
    std::lock_guard<std::mutex> guard { g_lock };
    for (auto& s : g_scripts) {
      if (s->call_command(name, args)) {
        return true;
      }
    }
  }

  // Встроенная команда: без неё спрятанную кнопку было бы нечем вернуть.
  if (name == "agloader") {
    gui::set_menu_open(!gui::menu_open());
    return true;
  }
  return false;
}

void on_pause()
{
  std::lock_guard<std::mutex> guard { g_lock };
  for (auto& s : g_scripts) {
    s->call_event_void("onPause");
  }
}

void on_resume()
{
  std::lock_guard<std::mutex> guard { g_lock };
  for (auto& s : g_scripts) {
    s->call_event_void("onResume");
  }
}

std::vector<Info> list()
{
  std::lock_guard<std::mutex> guard { g_lock };
  std::vector<Info> out;
  out.reserve(g_scripts.size());
  for (auto& s : g_scripts) {
    out.push_back(s->info());
  }
  return out;
}

void terminate(int id)
{
  std::lock_guard<std::mutex> guard { g_lock };
  for (auto& s : g_scripts) {
    if (s->info().id == id) {
      s->call_terminate();
      s->stop();
      return;
    }
  }
}

void restart(int id)
{
  std::lock_guard<std::mutex> guard { g_lock };
  for (auto& s : g_scripts) {
    if (s->info().id != id) {
      continue;
    }
    const std::string file = s->info().file;
    const std::string path = s->info().path;
    s->call_terminate();
    s->close();
    auto fresh = std::make_unique<Script>(id, file, path);
    if (fresh->load()) {
      fresh->start();
    } else {
      AG_LOGE("[%s] не перезапущен: %s", file.c_str(),
              fresh->info().error.c_str());
    }
    s = std::move(fresh);
    return;
  }
}

int running_count()
{
  std::lock_guard<std::mutex> guard { g_lock };
  int n = 0;
  for (auto& s : g_scripts) {
    const State st = s->info().state;
    if (st == State::Running || st == State::Sleeping) {
      ++n;
    }
  }
  return n;
}

}  // namespace ag::script::manager
