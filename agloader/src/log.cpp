// SPDX-License-Identifier: GPL-3.0-or-later
#include "log.h"

#include <cstdio>
#include <ctime>
#include <deque>
#include <mutex>

#if defined(__ANDROID__)
#include <android/log.h>
#endif

namespace ag::log {
namespace {

constexpr std::size_t kMaxTail = 512;

std::mutex g_lock;
std::FILE* g_file = nullptr;
std::deque<Line> g_tail;

const char* level_name(Level lvl)
{
  switch (lvl) {
    case Level::Debug: return "debug";
    case Level::Info: return "info";
    case Level::Warn: return "warn";
    case Level::Error: return "error";
    case Level::Script: return "script";
  }
  return "?";
}

#if defined(__ANDROID__)
int level_prio(Level lvl)
{
  switch (lvl) {
    case Level::Debug: return ANDROID_LOG_DEBUG;
    case Level::Info: return ANDROID_LOG_INFO;
    case Level::Warn: return ANDROID_LOG_WARN;
    case Level::Error: return ANDROID_LOG_ERROR;
    case Level::Script: return ANDROID_LOG_INFO;
  }
  return ANDROID_LOG_INFO;
}
#endif

}  // namespace

void init(const std::string& dir)
{
  std::lock_guard<std::mutex> guard { g_lock };
  if (g_file != nullptr) {
    std::fclose(g_file);
    g_file = nullptr;
  }
  const std::string path = dir + "/agloader.log";
  g_file = std::fopen(path.c_str(), "w");
}

void shutdown()
{
  std::lock_guard<std::mutex> guard { g_lock };
  if (g_file != nullptr) {
    std::fclose(g_file);
    g_file = nullptr;
  }
}

void writev(Level lvl, const char* tag, const char* fmt, va_list ap)
{
  char body[2048];
  std::vsnprintf(body, sizeof(body), fmt, ap);

#if defined(__ANDROID__)
  __android_log_write(level_prio(lvl), tag, body);
#else
  (void)tag;
#endif

  std::timespec ts {};
  std::timespec_get(&ts, TIME_UTC);
  std::tm tm {};
  localtime_r(&ts.tv_sec, &tm);

  char stamp[32];
  std::snprintf(stamp, sizeof(stamp), "%02d:%02d:%02d.%03ld", tm.tm_hour, tm.tm_min,
                tm.tm_sec, ts.tv_nsec / 1000000);

  std::lock_guard<std::mutex> guard { g_lock };
  if (g_file != nullptr) {
    std::fprintf(g_file, "[%s] (%s) %s\n", stamp, level_name(lvl), body);
    std::fflush(g_file);
  }
  g_tail.push_back(Line { lvl, body });
  while (g_tail.size() > kMaxTail) {
    g_tail.pop_front();
  }
}

void write(Level lvl, const char* tag, const char* fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  writev(lvl, tag, fmt, ap);
  va_end(ap);
}

std::vector<Line> tail(std::size_t max_lines)
{
  std::lock_guard<std::mutex> guard { g_lock };
  const std::size_t take = max_lines < g_tail.size() ? max_lines : g_tail.size();
  return std::vector<Line> { g_tail.end() - static_cast<long>(take), g_tail.end() };
}

void clear_tail()
{
  std::lock_guard<std::mutex> guard { g_lock };
  g_tail.clear();
}

}  // namespace ag::log
