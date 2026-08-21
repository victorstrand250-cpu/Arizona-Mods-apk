// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace ag::net {

// Состояние запроса. Скрипт опрашивает его, не блокируя поток отрисовки.
enum class State {
  Running,
  Done,
  Failed,
};

struct Response {
  State state = State::Running;
  int code = 0;
  std::string body;
  std::string error;
  std::map<std::string, std::string> headers;
};

struct Request {
  std::string method = "GET";
  std::string url;
  std::string body;
  std::map<std::string, std::string> headers;
  int timeout_ms = 15000;
};

// Запускает запрос в фоновом потоке и сразу возвращает номер.
// Ноль — не удалось даже начать.
int start(const Request& req);

// Текущее состояние. Ответ забирается один раз, дальше запрос можно освободить.
State poll(int id);
bool take(int id, Response* out);
void release(int id);

// Сколько запросов сейчас живо — для меню загрузчика.
std::size_t pending();

// Ждёт завершения фоновых потоков при выгрузке.
void shutdown();

}  // namespace ag::net
