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
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
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
// Android помечает указатели кучи: аллокатор кладёт метку в старший байт,
// железо её игнорирует (top-byte-ignore), а process_vm_readv — нет. Плюс
// такой указатель вылезает за 2^53 и теряет точность в числе Lua.
// Поэтому метку снимаем везде, где адрес пересекает границу с Lua.
constexpr std::uintptr_t untag(std::uintptr_t addr)
{
  return addr & 0x00FFFFFFFFFFFFFFull;
}

ssize_t read_partial(std::uintptr_t addr, void* dst, std::size_t len)
{
  addr = untag(addr);
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
  addr = untag(addr);
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

// ------------------------------------------------- поиск значения в памяти
//
// Классический сценарий Cheat Engine: находим все адреса с известным
// значением, ждём, пока оно в игре поменяется, и отсеиваем лишнее. Для
// движка без символов это единственный способ добраться до глобальных
// переменных вроде времени суток или погоды.

enum class ValueType { I8, U8, I16, U16, I32, U32, F32 };

bool parse_type(const char* name, ValueType* out, std::size_t* size)
{
  const struct { const char* name; ValueType type; std::size_t size; } kTypes[] = {
      { "i8", ValueType::I8, 1 },   { "u8", ValueType::U8, 1 },
      { "i16", ValueType::I16, 2 }, { "u16", ValueType::U16, 2 },
      { "i32", ValueType::I32, 4 }, { "u32", ValueType::U32, 4 },
      { "float", ValueType::F32, 4 },
  };
  for (const auto& t : kTypes) {
    if (std::strcmp(name, t.name) == 0) {
      *out = t.type;
      *size = t.size;
      return true;
    }
  }
  return false;
}

bool value_matches(const unsigned char* p, ValueType type, double want)
{
  switch (type) {
    case ValueType::I8:
      return static_cast<double>(*reinterpret_cast<const std::int8_t*>(p)) == want;
    case ValueType::U8:
      return static_cast<double>(*p) == want;
    case ValueType::I16:
      return static_cast<double>(*reinterpret_cast<const std::int16_t*>(p)) == want;
    case ValueType::U16:
      return static_cast<double>(*reinterpret_cast<const std::uint16_t*>(p)) == want;
    case ValueType::I32:
      return static_cast<double>(*reinterpret_cast<const std::int32_t*>(p)) == want;
    case ValueType::U32:
      return static_cast<double>(*reinterpret_cast<const std::uint32_t*>(p)) == want;
    case ValueType::F32: {
      const float f = *reinterpret_cast<const float*>(p);
      const double d = std::fabs(static_cast<double>(f) - want);
      return d <= 0.001;
    }
  }
  return false;
}

// Пределы, чтобы первый же поиск нуля не съел всю память под таблицу Lua.
constexpr int kMaxHits = 200000;

int l_regions(lua_State* L)
{
  const bool only_writable = lua_toboolean(L, 1) != 0;
  lua_newtable(L);
  int n = 0;
  for (const auto& reg : engine::regions()) {
    if (only_writable && !(reg.r && reg.w)) {
      continue;
    }
    lua_newtable(L);
    lua_pushnumber(L, static_cast<lua_Number>(reg.from));
    lua_setfield(L, -2, "from");
    lua_pushnumber(L, static_cast<lua_Number>(reg.to));
    lua_setfield(L, -2, "to");
    lua_pushnumber(L, static_cast<lua_Number>(reg.to - reg.from));
    lua_setfield(L, -2, "size");
    lua_pushboolean(L, reg.r ? 1 : 0);
    lua_setfield(L, -2, "read");
    lua_pushboolean(L, reg.w ? 1 : 0);
    lua_setfield(L, -2, "write");
    lua_pushboolean(L, reg.x ? 1 : 0);
    lua_setfield(L, -2, "exec");
    lua_pushstring(L, reg.name.c_str());
    lua_setfield(L, -2, "name");
    lua_rawseti(L, -2, ++n);
  }
  return 1;
}

// ─────────────────────────────────────────────────── поиск по структуре

// Собирает области для сканирования по тому же правилу, что и findvalue.
std::vector<engine::Range> scan_ranges(const char* where)
{
  std::vector<engine::Range> ranges;
  if (std::strcmp(where, "heap") != 0) {
    ranges = engine::client_data_ranges();
  }
  if (std::strcmp(where, "engine") != 0) {
    auto heap = engine::heap_ranges();
    ranges.insert(ranges.end(), heap.begin(), heap.end());
  }
  return ranges;
}

bool finite(float v)
{
  return v == v && v > -3.0e38f && v < 3.0e38f;
}

// Похож ли блок из 16 float на матрицу положения: верхний левый угол 3x3
// ортонормирован (оси единичной длины и взаимно перпендикулярны), а сдвиг
// лежит в разумных мировых пределах. Так выглядят матрицы камеры, игрока,
// транспорта и объектов — в librw они хранятся именно в таком виде.
bool looks_like_matrix(const float* m, float tol, float world_limit)
{
  for (int i = 0; i < 16; ++i) {
    if (!finite(m[i])) {
      return false;
    }
  }

  const float* r[3] = { m + 0, m + 4, m + 8 };
  for (const float* row : r) {
    const float len = row[0] * row[0] + row[1] * row[1] + row[2] * row[2];
    if (len < 1.0f - tol || len > 1.0f + tol) {
      return false;
    }
  }
  // Попарная перпендикулярность.
  for (int a = 0; a < 3; ++a) {
    for (int b = a + 1; b < 3; ++b) {
      const float d = r[a][0] * r[b][0] + r[a][1] * r[b][1] + r[a][2] * r[b][2];
      if (d > tol || d < -tol) {
        return false;
      }
    }
  }
  // Вырожденная единичная матрица встречается в памяти пачками и только
  // засоряет выдачу.
  const bool identity = m[0] > 0.999f && m[5] > 0.999f && m[10] > 0.999f &&
                        m[12] == 0.0f && m[13] == 0.0f && m[14] == 0.0f;
  if (identity) {
    return false;
  }

  for (int i = 12; i < 15; ++i) {
    if (m[i] > world_limit || m[i] < -world_limit) {
      return false;
    }
  }
  return true;
}

// memory.findmatrix([opts]) -> список адресов, число
//
// opts: { tol = 0.01, limit = 20000, world = 100000, where = 'all' }
int l_find_matrix(lua_State* L)
{
  float tol = 0.01f;
  float world_limit = 100000.0f;
  int limit = 20000;
  const char* where = "all";

  if (lua_istable(L, 1)) {
    lua_getfield(L, 1, "tol");
    if (lua_isnumber(L, -1)) tol = static_cast<float>(lua_tonumber(L, -1));
    lua_pop(L, 1);
    lua_getfield(L, 1, "world");
    if (lua_isnumber(L, -1)) world_limit = static_cast<float>(lua_tonumber(L, -1));
    lua_pop(L, 1);
    lua_getfield(L, 1, "limit");
    if (lua_isnumber(L, -1)) limit = static_cast<int>(lua_tonumber(L, -1));
    lua_pop(L, 1);
    lua_getfield(L, 1, "where");
    if (lua_isstring(L, -1)) where = lua_tostring(L, -1);
    lua_pop(L, 1);
  }

  auto ranges = scan_ranges(where);
  if (ranges.empty()) {
    lua_pushnil(L);
    lua_pushstring(L, "не нашёл областей для поиска");
    return 2;
  }

  lua_newtable(L);
  int found = 0;
  std::vector<unsigned char> buf;
  constexpr std::size_t kChunk = 1u << 20;
  constexpr std::size_t kMatrix = 16 * sizeof(float);

  for (const auto& range : ranges) {
    const std::size_t span = range.to - range.from;
    buf.resize(kChunk + kMatrix);

    for (std::size_t off = 0; off < span; off += kChunk) {
      const std::size_t want =
          span - off < kChunk + kMatrix ? span - off : kChunk + kMatrix;
      const ssize_t got = read_partial(range.from + off, buf.data(), want);
      if (got <= 0 || static_cast<std::size_t>(got) < kMatrix) {
        continue;
      }
      const std::size_t limit_bytes = static_cast<std::size_t>(got) - kMatrix;
      for (std::size_t i = 0; i <= limit_bytes; i += 4) {
        float m[16];
        std::memcpy(m, buf.data() + i, kMatrix);
        if (!looks_like_matrix(m, tol, world_limit)) {
          continue;
        }
        lua_pushnumber(L, static_cast<lua_Number>(range.from + off + i));
        lua_rawseti(L, -2, ++found);
        if (found >= limit) {
          lua_pushnumber(L, static_cast<lua_Number>(found));
          lua_pushboolean(L, 1);
          return 3;
        }
      }
    }
  }

  lua_pushnumber(L, found);
  lua_pushboolean(L, 0);
  return 3;
}

// Подсказка, где именно найден указатель: адрес внутри самой библиотеки
// сохраняется между запусками, адрес в куче — нет.
const char* elf_section_hint(std::uintptr_t addr)
{
  // client_data_ranges — это .data и .bss самой библиотеки: адрес там живёт
  // на фиксированном смещении от базы и переживает перезапуск.
  for (const auto& r : engine::client_data_ranges()) {
    if (addr >= r.from && addr < r.to) {
      return "модуль";
    }
  }
  return "куча";
}

// memory.readpositions(список, [сколько]) -> { {addr=, x=, y=, z=}, ... }
//
// Читает сдвиг сразу у многих матриц. Поштучное чтение здесь не годится:
// на пару сотен объектов это пара сотен системных вызовов каждый кадр.
// process_vm_readv умеет забрать несколько разрозненных кусков за один
// вызов, чем мы и пользуемся.
int l_read_positions(lua_State* L)
{
  luaL_checktype(L, 1, LUA_TTABLE);
  const int total = static_cast<int>(lua_objlen(L, 1));
  int want = static_cast<int>(luaL_optinteger(L, 2, total));
  if (want > total) {
    want = total;
  }
  if (want < 0) {
    want = 0;
  }

  // Ядро принимает не больше IOV_MAX кусков за раз.
  constexpr int kBatch = 512;
  constexpr std::size_t kVec = 3 * sizeof(float);
  constexpr std::size_t kPosOffset = 12 * sizeof(float);  // сдвиг в матрице

  lua_newtable(L);
  int out = 0;

  std::vector<std::uintptr_t> addrs;
  std::vector<float> data;
  std::vector<iovec> local;
  std::vector<iovec> remote;

  for (int start = 0; start < want; start += kBatch) {
    const int n = (want - start < kBatch) ? (want - start) : kBatch;

    addrs.clear();
    addrs.reserve(static_cast<std::size_t>(n));
    for (int i = 0; i < n; ++i) {
      lua_rawgeti(L, 1, start + i + 1);
      addrs.push_back(untag(static_cast<std::uintptr_t>(
          static_cast<long long>(lua_tonumber(L, -1)))));
      lua_pop(L, 1);
    }

    data.assign(static_cast<std::size_t>(n) * 3, 0.0f);
    local.clear();
    remote.clear();
    local.reserve(static_cast<std::size_t>(n));
    remote.reserve(static_cast<std::size_t>(n));

    for (int i = 0; i < n; ++i) {
      local.push_back(iovec { &data[static_cast<std::size_t>(i) * 3], kVec });
      remote.push_back(iovec {
          reinterpret_cast<void*>(addrs[static_cast<std::size_t>(i)] + kPosOffset),
          kVec });
    }

    const ssize_t got = ::process_vm_readv(::getpid(), local.data(),
                                           local.size(), remote.data(),
                                           remote.size(), 0);
    if (got <= 0) {
      continue;
    }
    // Ядро заполняет куски по порядку, поэтому сколько байт вернулось —
    // столько первых записей и достоверны.
    const int ok_count =
        static_cast<int>(static_cast<std::size_t>(got) / kVec);

    for (int i = 0; i < ok_count && i < n; ++i) {
      const float* v = &data[static_cast<std::size_t>(i) * 3];
      if (v[0] != v[0] || v[1] != v[1] || v[2] != v[2]) {
        continue;  // NaN — мусор, не показываем
      }
      lua_newtable(L);
      lua_pushnumber(L, static_cast<lua_Number>(addrs[static_cast<std::size_t>(i)]));
      lua_setfield(L, -2, "addr");
      lua_pushnumber(L, v[0]);
      lua_setfield(L, -2, "x");
      lua_pushnumber(L, v[1]);
      lua_setfield(L, -2, "y");
      lua_pushnumber(L, v[2]);
      lua_setfield(L, -2, "z");
      lua_rawseti(L, -2, ++out);
    }
  }

  lua_pushnumber(L, out);
  return 2;
}

// memory.findpointerto(addr, [opts]) -> список адресов, число
//
// Ищет 8-байтовые значения, равные заданному адресу (или попадающие в
// диапазон addr..addr+range). Матрицы камеры и игрока живут в куче, их адрес
// меняется при каждом запуске, а вот указатель на них где-то лежит — и если
// он окажется в .bss библиотеки, находку можно сохранить навсегда.
//
// opts: { range = 0, where = 'all' } — range > 0 ищет указатели на начало
// структуры, внутри которой лежит адрес, и возвращает ещё и смещение.
int l_find_pointer_to(lua_State* L)
{
  const auto target = untag(static_cast<std::uintptr_t>(
      static_cast<long long>(luaL_checknumber(L, 1))));
  std::uintptr_t range = 0;
  const char* where = "all";
  constexpr int kLimit = 20000;

  if (lua_istable(L, 2)) {
    lua_getfield(L, 2, "range");
    if (lua_isnumber(L, -1)) {
      range = static_cast<std::uintptr_t>(lua_tonumber(L, -1));
    }
    lua_pop(L, 1);
    lua_getfield(L, 2, "where");
    if (lua_isstring(L, -1)) where = lua_tostring(L, -1);
    lua_pop(L, 1);
  }

  auto ranges = scan_ranges(where);
  if (ranges.empty()) {
    lua_pushnil(L);
    lua_pushstring(L, "не нашёл областей для поиска");
    return 2;
  }

  lua_newtable(L);
  int found = 0;
  std::vector<unsigned char> buf;
  constexpr std::size_t kChunk = 1u << 20;
  constexpr std::size_t kPtr = sizeof(std::uintptr_t);

  for (const auto& reg : ranges) {
    const std::size_t span = reg.to - reg.from;
    buf.resize(kChunk + kPtr);

    for (std::size_t off = 0; off < span; off += kChunk) {
      const std::size_t want =
          span - off < kChunk + kPtr ? span - off : kChunk + kPtr;
      const ssize_t got = read_partial(reg.from + off, buf.data(), want);
      if (got <= 0 || static_cast<std::size_t>(got) < kPtr) {
        continue;
      }
      const std::size_t limit_bytes = static_cast<std::size_t>(got) - kPtr;
      // Указатели выровнены по 8, побайтовый проход только мусорил бы.
      for (std::size_t i = 0; i + kPtr <= limit_bytes + kPtr; i += 8) {
        std::uintptr_t v = 0;
        std::memcpy(&v, buf.data() + i, kPtr);
        v = untag(v);
        if (v != target && (range == 0 || v > target || target - v > range)) {
          continue;
        }
        // Пара: где лежит указатель и на сколько байт вглубь смотрит цель.
        lua_newtable(L);
        lua_pushnumber(L, static_cast<lua_Number>(reg.from + off + i));
        lua_setfield(L, -2, "at");
        lua_pushnumber(L, static_cast<lua_Number>(target - v));
        lua_setfield(L, -2, "offset");
        lua_pushstring(L, elf_section_hint(reg.from + off + i));
        lua_setfield(L, -2, "where");
        lua_rawseti(L, -2, ++found);

        if (found >= kLimit) {
          lua_pushnumber(L, static_cast<lua_Number>(found));
          lua_pushboolean(L, 1);
          return 3;
        }
      }
    }
  }

  lua_pushnumber(L, found);
  lua_pushboolean(L, 0);
  return 3;
}

// Похожи ли байты на осмысленный текст: печатные ASCII или кириллица UTF-8.
bool looks_like_text(const unsigned char* p, std::size_t len, std::size_t* used)
{
  std::size_t good = 0;
  std::size_t i = 0;
  while (i < len) {
    const unsigned char c = p[i];
    if (c == 0) {
      break;
    }
    if (c >= 0x20 && c < 0x7F) {
      ++good;
      ++i;
      continue;
    }
    // Двухбайтовая последовательность UTF-8 — сюда попадает кириллица.
    if (c >= 0xC2 && c <= 0xDF && i + 1 < len &&
        p[i + 1] >= 0x80 && p[i + 1] <= 0xBF) {
      good += 2;
      i += 2;
      continue;
    }
    break;
  }
  *used = i;
  // Три символа — уже не случайность, но и не каждый мусор.
  return good >= 3;
}

// memory.inspect(addr, [размер]) -> список строк по 8 байт
//
// Для каждой строки: смещение, байты, два int32, два float, и, если
// восьмёрка похожа на указатель, текст по этому адресу. Плюс попытка
// прочитать текст прямо здесь — короткие строки C++ лежат внутри объекта,
// а не по указателю.
//
// Этим ищутся поля, которых нет в разборе кода: ник, номер, здоровье.
int l_inspect(lua_State* L)
{
  const auto addr = untag(static_cast<std::uintptr_t>(
      static_cast<long long>(luaL_checknumber(L, 1))));
  std::size_t size = static_cast<std::size_t>(luaL_optinteger(L, 2, 256));
  if (size > 8192) {
    size = 8192;
  }
  size = (size + 7) & ~std::size_t { 7 };

  std::vector<unsigned char> buf(size, 0);
  const ssize_t got = read_partial(addr, buf.data(), size);
  if (got <= 0) {
    lua_pushnil(L);
    lua_pushstring(L, "адрес недоступен");
    return 2;
  }
  const std::size_t have = static_cast<std::size_t>(got) & ~std::size_t { 7 };

  lua_newtable(L);
  int row = 0;

  for (std::size_t off = 0; off + 8 <= have; off += 8) {
    const unsigned char* p = buf.data() + off;

    lua_newtable(L);
    lua_pushnumber(L, static_cast<lua_Number>(off));
    lua_setfield(L, -2, "off");

    char hex[24];
    std::snprintf(hex, sizeof(hex), "%02X %02X %02X %02X %02X %02X %02X %02X",
                  p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]);
    lua_pushstring(L, hex);
    lua_setfield(L, -2, "hex");

    std::int32_t i0 = 0, i1 = 0;
    float f0 = 0.0f, f1 = 0.0f;
    std::uintptr_t q = 0;
    std::memcpy(&i0, p, 4);
    std::memcpy(&i1, p + 4, 4);
    std::memcpy(&f0, p, 4);
    std::memcpy(&f1, p + 4, 4);
    std::memcpy(&q, p, 8);

    lua_pushnumber(L, static_cast<lua_Number>(i0));
    lua_setfield(L, -2, "i0");
    lua_pushnumber(L, static_cast<lua_Number>(i1));
    lua_setfield(L, -2, "i1");
    // NaN в Lua сравнивать неудобно, поэтому мусор отдаём как nil.
    if (f0 == f0 && f0 > -1e30f && f0 < 1e30f) {
      lua_pushnumber(L, f0);
      lua_setfield(L, -2, "f0");
    }
    if (f1 == f1 && f1 > -1e30f && f1 < 1e30f) {
      lua_pushnumber(L, f1);
      lua_setfield(L, -2, "f1");
    }

    // Текст прямо здесь — короткая строка C++ хранится внутри объекта.
    std::size_t used = 0;
    const std::size_t room = have - off;
    if (looks_like_text(p, room < 48 ? room : 48, &used)) {
      lua_pushlstring(L, reinterpret_cast<const char*>(p), used);
      lua_setfield(L, -2, "text");
    }

    // Текст по указателю — длинная строка лежит отдельно.
    const std::uintptr_t target = untag(q);
    if (target > 0x10000 && target < 0x1000000000000ull) {
      lua_pushnumber(L, static_cast<lua_Number>(target));
      lua_setfield(L, -2, "ptr");

      unsigned char probe[64] = {};
      const ssize_t n = read_partial(target, probe, sizeof(probe));
      if (n > 4) {
        std::size_t plen = 0;
        if (looks_like_text(probe, static_cast<std::size_t>(n), &plen)) {
          lua_pushlstring(L, reinterpret_cast<const char*>(probe), plen);
          lua_setfield(L, -2, "deref");
        }
      }
    }

    lua_rawseti(L, -2, ++row);
  }

  lua_pushnumber(L, row);
  return 2;
}

// memory.readmatrix(addr) -> таблица из 16 чисел
int l_read_matrix(lua_State* L)
{
  const auto addr = static_cast<std::uintptr_t>(
      static_cast<long long>(luaL_checknumber(L, 1)));
  float m[16];
  if (!safe_read(addr, m, sizeof(m))) {
    lua_pushnil(L);
    lua_pushstring(L, "адрес недоступен");
    return 2;
  }
  lua_newtable(L);
  for (int i = 0; i < 16; ++i) {
    lua_pushnumber(L, m[i]);
    lua_rawseti(L, -2, i + 1);
  }
  return 1;
}

// memory.findfloat3(x, y, z, eps, [opts]) -> список адресов, число
//
// Три подряд идущих float рядом с заданными — так ищется позиция, когда
// она уже известна из матрицы, но нужен другой её экземпляр в памяти.
int l_find_float3(lua_State* L)
{
  const float want_x = static_cast<float>(luaL_checknumber(L, 1));
  const float want_y = static_cast<float>(luaL_checknumber(L, 2));
  const float want_z = static_cast<float>(luaL_checknumber(L, 3));
  const float eps = static_cast<float>(luaL_optnumber(L, 4, 0.05));
  const char* where = luaL_optstring(L, 5, "all");
  constexpr int kLimit = 50000;

  auto ranges = scan_ranges(where);
  if (ranges.empty()) {
    lua_pushnil(L);
    lua_pushstring(L, "не нашёл областей для поиска");
    return 2;
  }

  lua_newtable(L);
  int found = 0;
  std::vector<unsigned char> buf;
  constexpr std::size_t kChunk = 1u << 20;
  constexpr std::size_t kVec = 3 * sizeof(float);

  for (const auto& range : ranges) {
    const std::size_t span = range.to - range.from;
    buf.resize(kChunk + kVec);

    for (std::size_t off = 0; off < span; off += kChunk) {
      const std::size_t want =
          span - off < kChunk + kVec ? span - off : kChunk + kVec;
      const ssize_t got = read_partial(range.from + off, buf.data(), want);
      if (got <= 0 || static_cast<std::size_t>(got) < kVec) {
        continue;
      }
      const std::size_t limit_bytes = static_cast<std::size_t>(got) - kVec;
      for (std::size_t i = 0; i <= limit_bytes; i += 4) {
        float v[3];
        std::memcpy(v, buf.data() + i, kVec);
        if (v[0] < want_x - eps || v[0] > want_x + eps) continue;
        if (v[1] < want_y - eps || v[1] > want_y + eps) continue;
        if (v[2] < want_z - eps || v[2] > want_z + eps) continue;

        lua_pushnumber(L, static_cast<lua_Number>(range.from + off + i));
        lua_rawseti(L, -2, ++found);
        if (found >= kLimit) {
          lua_pushnumber(L, static_cast<lua_Number>(found));
          lua_pushboolean(L, 1);
          return 3;
        }
      }
    }
  }

  lua_pushnumber(L, found);
  lua_pushboolean(L, 0);
  return 3;
}

int l_find_value(lua_State* L)
{
  const lua_Number want = luaL_checknumber(L, 1);
  const char* type_name = luaL_optstring(L, 2, "i32");

  ValueType type;
  std::size_t width = 0;
  if (!parse_type(type_name, &type, &width)) {
    lua_pushnil(L);
    lua_pushstring(L, "неизвестный тип значения");
    return 2;
  }

  // Третьим аргументом — где искать. По умолчанию везде: переменные игры
  // почти всегда лежат в куче внутри синглтона, а не в .bss библиотеки.
  const char* where = luaL_optstring(L, 3, "all");
  const bool want_engine = std::strcmp(where, "heap") != 0;
  const bool want_heap = std::strcmp(where, "engine") != 0;

  std::vector<engine::Range> ranges;
  if (want_engine) {
    ranges = engine::client_data_ranges();
  }
  if (want_heap) {
    auto heap = engine::heap_ranges();
    ranges.insert(ranges.end(), heap.begin(), heap.end());
  }
  if (ranges.empty()) {
    lua_pushnil(L);
    lua_pushstring(L, "не нашёл областей для поиска");
    return 2;
  }

  lua_newtable(L);
  int found = 0;
  std::vector<unsigned char> buf;

  for (const auto& range : ranges) {
    const std::size_t span = range.to - range.from;
    constexpr std::size_t kChunk = 1u << 20;
    buf.resize(kChunk + 8);

    for (std::size_t off = 0; off < span; off += kChunk) {
      const std::size_t want_bytes =
          span - off < kChunk + width ? span - off : kChunk + width;
      const ssize_t got = read_partial(range.from + off, buf.data(), want_bytes);
      if (got <= 0 || static_cast<std::size_t>(got) < width) {
        continue;
      }
      const std::size_t limit = static_cast<std::size_t>(got) - width;
      // Шаг — по размеру значения: игровые переменные выровнены,
      // а побайтовый проход дал бы гору мусорных совпадений.
      for (std::size_t i = 0; i <= limit; i += width) {
        if (!value_matches(buf.data() + i, type, want)) {
          continue;
        }
        lua_pushnumber(L, static_cast<lua_Number>(range.from + off + i));
        lua_rawseti(L, -2, ++found);
        if (found >= kMaxHits) {
          // Второе значение всегда число: раньше здесь возвращалась строка,
          // и вызывающий код падал на форматировании счётчика.
          lua_pushnumber(L, static_cast<lua_Number>(found));
          lua_pushboolean(L, 1);  // список обрезан
          return 3;
        }
      }
    }
  }

  lua_pushnumber(L, found);
  lua_pushboolean(L, 0);
  return 3;
}

// Читает указатель по адресу. Нужен, чтобы от базы библиотеки дойти до
// синглтона в куче: адрес самого синглтона от запуска к запуску меняется,
// а смещение поля внутри него — нет.
int l_deref(lua_State* L)
{
  const auto addr = static_cast<std::uintptr_t>(
      static_cast<long long>(luaL_checknumber(L, 1)));
  std::uintptr_t value = 0;
  if (!safe_read(addr, &value, sizeof(value))) {
    lua_pushnil(L);
    lua_pushstring(L, "адрес недоступен");
    return 2;
  }
  lua_pushnumber(L, static_cast<lua_Number>(untag(value)));
  return 1;
}

int l_refine(lua_State* L)
{
  luaL_checktype(L, 1, LUA_TTABLE);
  const lua_Number want = luaL_checknumber(L, 2);
  const char* type_name = luaL_optstring(L, 3, "i32");

  ValueType type;
  std::size_t width = 0;
  if (!parse_type(type_name, &type, &width)) {
    lua_pushnil(L);
    lua_pushstring(L, "неизвестный тип значения");
    return 2;
  }

  const int count = static_cast<int>(lua_objlen(L, 1));
  lua_newtable(L);
  int kept = 0;
  unsigned char probe[8] = {};

  for (int i = 1; i <= count; ++i) {
    lua_rawgeti(L, 1, i);
    const auto addr = static_cast<std::uintptr_t>(
        static_cast<long long>(lua_tonumber(L, -1)));
    lua_pop(L, 1);

    if (!safe_read(addr, probe, width)) {
      continue;
    }
    if (!value_matches(probe, type, want)) {
      continue;
    }
    lua_pushnumber(L, static_cast<lua_Number>(addr));
    lua_rawseti(L, -2, ++kept);
  }

  lua_pushnumber(L, kept);
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
    { "regions", l_regions },
    { "findvalue", l_find_value },
    { "refine", l_refine },
    { "findmatrix", l_find_matrix },
    { "readmatrix", l_read_matrix },
    { "findfloat3", l_find_float3 },
    { "findpointerto", l_find_pointer_to },
    { "readpositions", l_read_positions },
    { "inspect", l_inspect },
    { "deref", l_deref },
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
