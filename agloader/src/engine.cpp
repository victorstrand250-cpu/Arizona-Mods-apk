// SPDX-License-Identifier: GPL-3.0-or-later
#include "engine.h"

#include <dlfcn.h>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <map>
#include <thread>

#include "log.h"

namespace ag::engine {
namespace {

constexpr const char* kClientSo = "libag-client.so";

// Имена JNI-функций движка. Резолвятся через dlsym по хендлу libag-client.so,
// а не через RTLD_DEFAULT: иначе dlsym нашёл бы наши собственные обёртки.
constexpr const char* kSymInit = "Java_com_arizonagames_client_game_core_JNILib_androidInit";
constexpr const char* kSymStep = "Java_com_arizonagames_client_game_core_JNILib_androidStep";
constexpr const char* kSymResize = "Java_com_arizonagames_client_game_core_JNILib_androidResize";
constexpr const char* kSymTouch = "Java_com_arizonagames_client_game_core_JNILib_androidMultiTouch";
constexpr const char* kSymKey = "Java_com_arizonagames_client_game_core_JNILib_androidKeyEvent";
constexpr const char* kSymPause = "Java_com_arizonagames_client_game_core_JNILib_androidPause";
constexpr const char* kSymResume = "Java_com_arizonagames_client_game_core_JNILib_androidResume";
constexpr const char* kSymInputEnd = "Java_com_arizona_game_GTASA_OnInputEnd";
constexpr const char* kSymKbdClosed =
    "Java_com_arizona_game_GTASA_OnKeyboardClosed";

Anchors g_anchors;
bool g_resolved = false;
Module g_client;

template <typename T>
T sym(void* handle, const char* name, int* missing)
{
  void* p = ::dlsym(handle, name);
  if (p == nullptr) {
    AG_LOGE("dlsym(%s) не найден", name);
    ++*missing;
  }
  return reinterpret_cast<T>(p);
}

}  // namespace

std::vector<Module> modules()
{
  std::vector<Module> out;
  std::FILE* f = std::fopen("/proc/self/maps", "r");
  if (f == nullptr) {
    return out;
  }

  std::map<std::string, Module> acc;
  char line[1024];
  while (std::fgets(line, sizeof(line), f) != nullptr) {
    unsigned long long start = 0;
    unsigned long long end = 0;
    char perms[8] = {};
    int path_off = 0;
    if (std::sscanf(line, "%llx-%llx %7s %*s %*s %*s %n", &start, &end, perms,
                    &path_off) < 3) {
      continue;
    }
    if (path_off <= 0) {
      continue;
    }
    std::string path { line + path_off };
    while (!path.empty() && (path.back() == '\n' || path.back() == ' ')) {
      path.pop_back();
    }
    if (path.empty() || path[0] != '/') {
      continue;
    }

    auto it = acc.find(path);
    if (it == acc.end()) {
      Module m;
      m.path = path;
      m.base = static_cast<std::uintptr_t>(start);
      m.end = static_cast<std::uintptr_t>(end);
      acc.emplace(path, m);
    } else {
      if (start < it->second.base) {
        it->second.base = static_cast<std::uintptr_t>(start);
      }
      if (end > it->second.end) {
        it->second.end = static_cast<std::uintptr_t>(end);
      }
    }
  }
  std::fclose(f);

  out.reserve(acc.size());
  for (auto& kv : acc) {
    out.push_back(kv.second);
  }
  return out;
}

std::vector<Region> regions()
{
  std::vector<Region> out;
  std::FILE* f = std::fopen("/proc/self/maps", "r");
  if (f == nullptr) {
    return out;
  }

  char line[1024];
  while (std::fgets(line, sizeof(line), f) != nullptr) {
    unsigned long long start = 0;
    unsigned long long end = 0;
    char perms[8] = {};
    int path_off = 0;
    if (std::sscanf(line, "%llx-%llx %7s %*s %*s %*s %n", &start, &end, perms,
                    &path_off) < 3) {
      continue;
    }

    Region reg;
    reg.from = static_cast<std::uintptr_t>(start);
    reg.to = static_cast<std::uintptr_t>(end);
    reg.r = perms[0] == 'r';
    reg.w = perms[1] == 'w';
    reg.x = perms[2] == 'x';
    if (path_off > 0) {
      reg.name = line + path_off;
      while (!reg.name.empty() &&
             (reg.name.back() == '\n' || reg.name.back() == ' ')) {
        reg.name.pop_back();
      }
    }
    out.push_back(std::move(reg));
  }
  std::fclose(f);
  return out;
}

std::vector<Range> client_data_ranges()
{
  std::vector<Range> out;
  if (g_client.path.empty()) {
    return out;
  }

  const auto all = regions();
  std::uintptr_t chain_end = 0;  // докуда тянется непрерывная цепочка от модуля

  for (const auto& reg : all) {
    const bool is_client = reg.name == g_client.path;
    // .bss отображается анонимно вплотную к последнему сегменту библиотеки.
    const bool is_tail =
        chain_end != 0 && reg.from == chain_end &&
        (reg.name.empty() || reg.name.compare(0, 6, "[anon:") == 0);

    if (!is_client && !is_tail) {
      if (chain_end != 0 && reg.from > chain_end) {
        chain_end = 0;  // цепочка прервалась
      }
      continue;
    }

    chain_end = reg.to;
    if (reg.r && reg.w) {
      if (!out.empty() && out.back().to == reg.from) {
        out.back().to = reg.to;  // склеиваем соседние
      } else {
        out.push_back(Range { reg.from, reg.to });
      }
    }
  }
  return out;
}

std::vector<Range> heap_ranges()
{
  std::vector<Range> out;
  for (const auto& reg : regions()) {
    if (!reg.r || !reg.w) {
      continue;
    }
    // Только безымянные отображения: файловые — это библиотеки и ресурсы,
    // искать переменные игры там нет смысла.
    if (!reg.name.empty() && reg.name.compare(0, 6, "[anon:") != 0) {
      continue;
    }
    // Стек трогать не нужно: там временные значения текущего кадра.
    if (reg.name.compare(0, 6, "[stack") == 0) {
      continue;
    }
    if (!out.empty() && out.back().to == reg.from) {
      out.back().to = reg.to;
    } else {
      out.push_back(Range { reg.from, reg.to });
    }
  }
  return out;
}

bool find_module(const std::string& name_suffix, Module* out)
{
  if (name_suffix.empty()) {
    return false;
  }
  for (auto& m : modules()) {
    const std::size_t slash = m.path.find_last_of('/');
    const std::string file =
        slash == std::string::npos ? m.path : m.path.substr(slash + 1);

    const bool by_name = file == name_suffix;
    const bool by_suffix =
        m.path.size() >= name_suffix.size() &&
        m.path.compare(m.path.size() - name_suffix.size(), name_suffix.size(),
                       name_suffix) == 0;
    if (by_name || by_suffix) {
      if (out != nullptr) {
        *out = m;
      }
      return true;
    }
  }
  return false;
}

bool wait_and_resolve(int timeout_ms)
{
  void* handle = nullptr;
  int waited = 0;
  while (true) {
    // RTLD_NOLOAD: не грузим движок сами, только цепляемся к уже загруженному.
    handle = ::dlopen(kClientSo, RTLD_NOW | RTLD_NOLOAD);
    if (handle != nullptr) {
      break;
    }
    if (timeout_ms >= 0 && waited >= timeout_ms) {
      AG_LOGE("%s не появился за %d мс", kClientSo, timeout_ms);
      return false;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
    waited += 2;
  }

  int missing = 0;
  g_anchors.android_init =
      sym<decltype(Anchors::android_init)>(handle, kSymInit, &missing);
  g_anchors.android_step =
      sym<decltype(Anchors::android_step)>(handle, kSymStep, &missing);
  g_anchors.android_resize =
      sym<decltype(Anchors::android_resize)>(handle, kSymResize, &missing);
  g_anchors.android_multi_touch =
      sym<decltype(Anchors::android_multi_touch)>(handle, kSymTouch, &missing);
  g_anchors.android_key_event =
      sym<decltype(Anchors::android_key_event)>(handle, kSymKey, &missing);
  g_anchors.android_pause =
      sym<decltype(Anchors::android_pause)>(handle, kSymPause, &missing);
  g_anchors.android_resume =
      sym<decltype(Anchors::android_resume)>(handle, kSymResume, &missing);
  g_anchors.on_input_end =
      sym<decltype(Anchors::on_input_end)>(handle, kSymInputEnd, &missing);
  g_anchors.on_keyboard_closed =
      sym<decltype(Anchors::on_keyboard_closed)>(handle, kSymKbdClosed, &missing);

  // Хендл намеренно не закрываем: движок должен остаться загруженным,
  // а указатели — валидными до конца процесса.

  find_module(kClientSo, &g_client);

  if (missing != 0) {
    AG_LOGE("не найдено якорей: %d — движок несовместим", missing);
    return false;
  }

  AG_LOGI("движок найден: %s [%p .. %p], %zu КБ", g_client.path.c_str(),
          reinterpret_cast<void*>(g_client.base),
          reinterpret_cast<void*>(g_client.end), client_size() / 1024);
  AG_LOGI("androidStep = %p", reinterpret_cast<void*>(g_anchors.android_step));

  g_resolved = true;
  return true;
}

bool resolved() { return g_resolved; }
const Anchors& anchors() { return g_anchors; }
std::uintptr_t client_base() { return g_client.base; }
std::size_t client_size()
{
  return g_client.end > g_client.base ? g_client.end - g_client.base : 0;
}

}  // namespace ag::engine
