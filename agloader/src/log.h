// AGLoader — Lua-загрузчик для нового движка Arizona Mobile (libag-client.so)
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstdarg>
#include <string>
#include <vector>

namespace ag::log {

enum class Level { Debug, Info, Warn, Error, Script };

// Открывает файл лога в <data>/logs/agloader.log. Можно звать повторно.
void init(const std::string& dir);
void shutdown();

void writev(Level lvl, const char* tag, const char* fmt, va_list ap);
void write(Level lvl, const char* tag, const char* fmt, ...)
    __attribute__((format(printf, 3, 4)));

// Последние строки — для встроенной консоли в меню.
struct Line {
  Level lvl;
  std::string text;
};
// Снимок кольцевого буфера. Безопасно звать из GL-потока.
std::vector<Line> tail(std::size_t max_lines);
void clear_tail();

}  // namespace ag::log

#define AG_LOGD(...) ::ag::log::write(::ag::log::Level::Debug, "agloader", __VA_ARGS__)
#define AG_LOGI(...) ::ag::log::write(::ag::log::Level::Info, "agloader", __VA_ARGS__)
#define AG_LOGW(...) ::ag::log::write(::ag::log::Level::Warn, "agloader", __VA_ARGS__)
#define AG_LOGE(...) ::ag::log::write(::ag::log::Level::Error, "agloader", __VA_ARGS__)
