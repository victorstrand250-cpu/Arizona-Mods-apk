// SPDX-License-Identifier: GPL-3.0-or-later
//
// memory.* — работа с памятью процесса.
//
// Движок stripped, поэтому вся «полезная нагрузка» скриптов упирается в то,
// чтобы найти нужный адрес и прочитать/записать по нему. Отсюда два акцента:
//   * чтение и запись идут через process_vm_readv/writev по самому себе —
//     неверный адрес возвращает ошибку вместо SIGSEGV и падения игры;
//   * есть memory.scan — поиск по сигнатуре, единственный практичный способ
//     находить функции в бинарнике без символов.
#include <sys/mman.h>
#include <sys/uio.h>
#include <unistd.h>

#include <cctype>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "engine.h"
#include "log.h"
#include "lua.hpp"
#include "script/api.h"

namespace ag::script::api {
namespace {

std::uintptr_t to_addr(lua_State* L, int idx)
{
  if (lua_type(L, idx) == LUA_TSTRING) {
    const char* s = lua_tostring(L, idx);
    return static_cast<std::uintptr_t>(std::strtoull(s, nullptr, 0));
  }
  return static_cast<std::uintptr_t>(
      static_cast<long long>(luaL_checknumber(L, idx)));
}

// Безопасное чтение своей же, но потенциально невалидной памяти: ошибка
// адреса приходит кодом возврата, а не SIGSEGV. Для процесса, читающего сам
// себя, ядро пропускает проверку ptrace (same_thread_group), так что ни
// разрешений, ни SELinux-политики это не требует.
//
// Возвращает, сколько байт реально прочитано: диапазон может обрываться на
// неотображённой странице, и для сканера сигнатур полезнее получить начало,
// чем ничего.
ssize_t read_partial(std::uintptr_t addr, void* dst, std::size_t len)
{
  if (addr == 0 || len == 0) {
    return 0;
  }
  iovec local { dst, len };
  iovec remote { reinterpret_cast<void*>(addr), len };
  return ::process_vm_readv(::getpid(), &local, 1, &remote, 1, 0);
}

bool safe_read(std::uintptr_t addr, void* dst, std::size_t len)
{
  return read_partial(addr, dst, len) == static_cast<ssize_t>(len);
}

bool safe_write(std::uintptr_t addr, const void* src, std::size_t len)
{
  if (addr == 0 || len == 0) {
    return false;
  }
  iovec local { const_cast<void*>(src), len };
  iovec remote { reinterpret_cast<void*>(addr), len };
  const ssize_t n = ::process_vm_writev(::getpid(), &local, 1, &remote, 1, 0);
  return n == static_cast<ssize_t>(len);
}

bool unprotect(std::uintptr_t addr, std::size_t len)
{
  const std::size_t page = static_cast<std::size_t>(::sysconf(_SC_PAGESIZE));
  const std::uintptr_t start = addr & ~(page - 1);
  const std::uintptr_t end = (addr + len + page - 1) & ~(page - 1);
  return ::mprotect(reinterpret_cast<void*>(start), end - start,
                    PROT_READ | PROT_WRITE | PROT_EXEC) == 0;
}

// ------------------------------------------------------------- модули

int l_get_module_base(lua_State* L)
{
  const char* name = luaL_checkstring(L, 1);
  engine::Module m;
  if (!engine::find_module(name, &m)) {
    lua_pushnil(L);
    lua_pushstring(L, "модуль не найден");
    return 2;
  }
  lua_pushnumber(L, static_cast<lua_Number>(m.base));
  lua_pushnumber(L, static_cast<lua_Number>(m.end - m.base));
  lua_pushstring(L, m.path.c_str());
  return 3;
}

int l_get_client_base(lua_State* L)
{
  lua_pushnumber(L, static_cast<lua_Number>(engine::client_base()));
  lua_pushnumber(L, static_cast<lua_Number>(engine::client_size()));
  return 2;
}

int l_get_modules(lua_State* L)
{
  const auto mods = engine::modules();
  lua_newtable(L);
  int n = 0;
  for (const auto& m : mods) {
    const std::size_t slash = m.path.find_last_of('/');
    const std::string file =
        slash == std::string::npos ? m.path : m.path.substr(slash + 1);
    lua_newtable(L);
    lua_pushstring(L, file.c_str());
    lua_setfield(L, -2, "name");
    lua_pushstring(L, m.path.c_str());
    lua_setfield(L, -2, "path");
    lua_pushnumber(L, static_cast<lua_Number>(m.base));
    lua_setfield(L, -2, "base");
    lua_pushnumber(L, static_cast<lua_Number>(m.end - m.base));
    lua_setfield(L, -2, "size");
    lua_rawseti(L, -2, ++n);
  }
  return 1;
}

// ---------------------------------------------------------- чтение/запись

int l_read(lua_State* L)
{
  const std::uintptr_t addr = to_addr(L, 1);
  const lua_Integer size = luaL_checkinteger(L, 2);
  if (size <= 0 || size > (1 << 20)) {
    lua_pushnil(L);
    lua_pushstring(L, "недопустимый размер");
    return 2;
  }
  std::vector<char> buf(static_cast<std::size_t>(size));
  if (!safe_read(addr, buf.data(), buf.size())) {
    lua_pushnil(L);
    lua_pushstring(L, std::strerror(errno));
    return 2;
  }
  lua_pushlstring(L, buf.data(), buf.size());
  return 1;
}

int l_write(lua_State* L)
{
  const std::uintptr_t addr = to_addr(L, 1);
  std::size_t len = 0;
  const char* data = luaL_checklstring(L, 2, &len);
  const bool force = lua_toboolean(L, 3) != 0;

  if (force) {
    unprotect(addr, len);
  }
  const bool ok = safe_write(addr, data, len);
  lua_pushboolean(L, ok ? 1 : 0);
  if (!ok) {
    lua_pushstring(L, std::strerror(errno));
    return 2;
  }
  return 1;
}

template <typename T>
int read_scalar(lua_State* L)
{
  const std::uintptr_t addr = to_addr(L, 1);
  T value {};
  if (!safe_read(addr, &value, sizeof(T))) {
    lua_pushnil(L);
    lua_pushstring(L, std::strerror(errno));
    return 2;
  }
  lua_pushnumber(L, static_cast<lua_Number>(value));
  return 1;
}

template <typename T>
int write_scalar(lua_State* L)
{
  const std::uintptr_t addr = to_addr(L, 1);
  const lua_Number raw = luaL_checknumber(L, 2);
  const bool force = lua_toboolean(L, 3) != 0;
  const T value = static_cast<T>(raw);

  if (force) {
    unprotect(addr, sizeof(T));
  }
  const bool ok = safe_write(addr, &value, sizeof(T));
  lua_pushboolean(L, ok ? 1 : 0);
  return 1;
}

int l_read_string(lua_State* L)
{
  const std::uintptr_t addr = to_addr(L, 1);
  const lua_Integer max = luaL_optinteger(L, 2, 256);
  if (max <= 0 || max > (1 << 16)) {
    lua_pushnil(L);
    lua_pushstring(L, "недопустимая длина");
    return 2;
  }
  std::vector<char> buf(static_cast<std::size_t>(max) + 1, '\0');
  // Читаем по чуть-чуть: строка может упираться в конец отображённой страницы.
  std::size_t got = 0;
  while (got < static_cast<std::size_t>(max)) {
    const std::size_t chunk =
        static_cast<std::size_t>(max) - got > 64 ? 64 : static_cast<std::size_t>(max) - got;
    if (!safe_read(addr + got, buf.data() + got, chunk)) {
      break;
    }
    got += chunk;
    if (std::memchr(buf.data(), 0, got) != nullptr) {
      break;
    }
  }
  if (got == 0) {
    lua_pushnil(L);
    lua_pushstring(L, "не удалось прочитать");
    return 2;
  }
  lua_pushstring(L, buf.data());
  return 1;
}

int l_is_valid(lua_State* L)
{
  const std::uintptr_t addr = to_addr(L, 1);
  const lua_Integer size = luaL_optinteger(L, 2, 1);
  std::vector<char> buf(static_cast<std::size_t>(size > 0 ? size : 1));
  lua_pushboolean(L, safe_read(addr, buf.data(), buf.size()) ? 1 : 0);
  return 1;
}

int l_protect(lua_State* L)
{
  const std::uintptr_t addr = to_addr(L, 1);
  const lua_Integer size = luaL_checkinteger(L, 2);
  lua_pushboolean(L, unprotect(addr, static_cast<std::size_t>(size)) ? 1 : 0);
  return 1;
}

int l_hex(lua_State* L)
{
  const std::uintptr_t addr = to_addr(L, 1);
  const lua_Integer size = luaL_optinteger(L, 2, 32);
  if (size <= 0 || size > 4096) {
    lua_pushnil(L);
    return 1;
  }
  std::vector<unsigned char> buf(static_cast<std::size_t>(size));
  if (!safe_read(addr, buf.data(), buf.size())) {
    lua_pushnil(L);
    lua_pushstring(L, std::strerror(errno));
    return 2;
  }
  std::string out;
  out.reserve(buf.size() * 3);
  static const char* kHex = "0123456789ABCDEF";
  for (std::size_t i = 0; i < buf.size(); ++i) {
    out.push_back(kHex[buf[i] >> 4]);
    out.push_back(kHex[buf[i] & 0x0F]);
    out.push_back(' ');
  }
  lua_pushlstring(L, out.data(), out.size());
  return 1;
}

// ----------------------------------------------------- поиск по сигнатуре

struct PatternByte {
  unsigned char value;
  bool wildcard;
};

bool parse_pattern(const char* text, std::vector<PatternByte>* out)
{
  out->clear();
  const char* p = text;
  while (*p != '\0') {
    while (*p == ' ' || *p == '\t') {
      ++p;
    }
    if (*p == '\0') {
      break;
    }
    if (*p == '?') {
      ++p;
      if (*p == '?') {
        ++p;
      }
      out->push_back(PatternByte { 0, true });
      continue;
    }
    unsigned int value = 0;
    int digits = 0;
    while (digits < 2 && std::isxdigit(static_cast<unsigned char>(*p))) {
      const char c = *p++;
      const unsigned int d = (c >= '0' && c <= '9')   ? static_cast<unsigned>(c - '0')
                             : (c >= 'a' && c <= 'f') ? static_cast<unsigned>(c - 'a' + 10)
                                                      : static_cast<unsigned>(c - 'A' + 10);
      value = (value << 4) | d;
      ++digits;
    }
    if (digits == 0) {
      return false;
    }
    out->push_back(PatternByte { static_cast<unsigned char>(value), false });
  }
  return !out->empty();
}

int l_scan(lua_State* L)
{
  const char* pattern_text = luaL_checkstring(L, 1);
  const char* module_name = luaL_optstring(L, 2, "libag-client.so");
  const lua_Integer want_index = luaL_optinteger(L, 3, 1);

  std::vector<PatternByte> pattern;
  if (!parse_pattern(pattern_text, &pattern)) {
    lua_pushnil(L);
    lua_pushstring(L, "не разобрал сигнатуру");
    return 2;
  }

  engine::Module m;
  if (!engine::find_module(module_name, &m)) {
    lua_pushnil(L);
    lua_pushstring(L, "модуль не найден");
    return 2;
  }

  const std::size_t span = m.end - m.base;
  if (span == 0 || pattern.size() > span) {
    lua_pushnil(L);
    lua_pushstring(L, "пустой диапазон");
    return 2;
  }

  // Копируем модуль страницами: часть отображения может быть недоступна,
  // такие куски просто пропускаем.
  constexpr std::size_t kChunk = 1u << 20;
  std::vector<unsigned char> buf(kChunk + pattern.size());

  lua_Integer found = 0;
  for (std::size_t off = 0; off < span; off += kChunk) {
    const std::size_t want = span - off < kChunk + pattern.size()
                                 ? span - off
                                 : kChunk + pattern.size();
    // Частичное чтение — норма: у модуля есть неотображённые дыры.
    // Берём то, что дали, вместо того чтобы терять целый мегабайт.
    const ssize_t got = read_partial(m.base + off, buf.data(), want);
    if (got <= 0 || static_cast<std::size_t>(got) < pattern.size()) {
      continue;
    }
    const std::size_t limit = static_cast<std::size_t>(got) - pattern.size();
    for (std::size_t i = 0; i <= limit; ++i) {
      bool hit = true;
      for (std::size_t j = 0; j < pattern.size(); ++j) {
        if (!pattern[j].wildcard && buf[i + j] != pattern[j].value) {
          hit = false;
          break;
        }
      }
      if (!hit) {
        continue;
      }
      if (++found == want_index) {
        lua_pushnumber(L, static_cast<lua_Number>(m.base + off + i));
        lua_pushnumber(L, static_cast<lua_Number>(off + i));
        return 2;
      }
    }
  }

  lua_pushnil(L);
  lua_pushstring(L, "сигнатура не найдена");
  return 2;
}

const luaL_Reg kMemory[] = {
    { "getmodulebase", l_get_module_base },
    { "getclientbase", l_get_client_base },
    { "getmodules", l_get_modules },
    { "read", l_read },
    { "write", l_write },
    { "readstring", l_read_string },
    { "isvalid", l_is_valid },
    { "protect", l_protect },
    { "hex", l_hex },
    { "scan", l_scan },
    { "readi8", read_scalar<std::int8_t> },
    { "readu8", read_scalar<std::uint8_t> },
    { "readi16", read_scalar<std::int16_t> },
    { "readu16", read_scalar<std::uint16_t> },
    { "readi32", read_scalar<std::int32_t> },
    { "readu32", read_scalar<std::uint32_t> },
    { "readi64", read_scalar<std::int64_t> },
    { "readu64", read_scalar<std::uint64_t> },
    { "readfloat", read_scalar<float> },
    { "readdouble", read_scalar<double> },
    { "writei8", write_scalar<std::int8_t> },
    { "writeu8", write_scalar<std::uint8_t> },
    { "writei16", write_scalar<std::int16_t> },
    { "writeu16", write_scalar<std::uint16_t> },
    { "writei32", write_scalar<std::int32_t> },
    { "writeu32", write_scalar<std::uint32_t> },
    { "writei64", write_scalar<std::int64_t> },
    { "writeu64", write_scalar<std::uint64_t> },
    { "writefloat", write_scalar<float> },
    { "writedouble", write_scalar<double> },
    { nullptr, nullptr },
};

}  // namespace

void open_memory(lua_State* L)
{
  lua_newtable(L);
  for (const luaL_Reg* r = kMemory; r->name != nullptr; ++r) {
    lua_pushcfunction(L, r->func);
    lua_setfield(L, -2, r->name);
  }
  lua_setglobal(L, "memory");
}

}  // namespace ag::script::api
