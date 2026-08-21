// SPDX-License-Identifier: GPL-3.0-or-later
#include "paths.h"

#include <sys/stat.h>
#include <sys/types.h>

#include <cerrno>
#include <cstdio>
#include <cstring>

namespace ag::paths {
namespace {

std::string g_package;
std::string g_root;
std::string g_scripts;
std::string g_lib;
std::string g_config;
std::string g_logs;

std::string read_package_name()
{
  std::FILE* f = std::fopen("/proc/self/cmdline", "rb");
  if (f == nullptr) {
    return {};
  }
  char buf[512] = {};
  const std::size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
  std::fclose(f);
  if (n == 0) {
    return {};
  }
  // cmdline — это NUL-разделённый список, имя процесса идёт первым.
  std::string name { buf };
  // У изолированных/приватных процессов имя вида "com.pkg:remote".
  const std::size_t colon = name.find(':');
  if (colon != std::string::npos) {
    name.resize(colon);
  }
  return name;
}

bool mkdir_p(const std::string& path)
{
  if (path.empty()) {
    return false;
  }
  std::string acc;
  acc.reserve(path.size());
  for (std::size_t i = 0; i < path.size(); ++i) {
    acc.push_back(path[i]);
    const bool last = (i + 1 == path.size());
    if (path[i] == '/' || last) {
      if (acc == "/") {
        continue;
      }
      std::string dir = acc;
      if (dir.size() > 1 && dir.back() == '/') {
        dir.pop_back();
      }
      if (::mkdir(dir.c_str(), 0775) != 0 && errno != EEXIST) {
        return false;
      }
    }
  }
  return true;
}

}  // namespace

bool init()
{
  g_package = read_package_name();
  if (g_package.empty()) {
    g_package = "unknown";
  }

  g_root = "/sdcard/Android/media/" + g_package + "/agloader";
  g_scripts = g_root + "/scripts";
  g_lib = g_root + "/lib";
  g_config = g_root + "/config";
  g_logs = g_root + "/logs";

  bool ok = true;
  ok = mkdir_p(g_scripts) && ok;
  ok = mkdir_p(g_lib) && ok;
  ok = mkdir_p(g_config) && ok;
  ok = mkdir_p(g_logs) && ok;
  return ok;
}

const std::string& package() { return g_package; }
const std::string& root() { return g_root; }
const std::string& scripts() { return g_scripts; }
const std::string& lua_lib() { return g_lib; }
const std::string& config() { return g_config; }
const std::string& logs() { return g_logs; }

}  // namespace ag::paths
