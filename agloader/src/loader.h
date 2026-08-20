// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <jni.h>

#include <string>

namespace ag::loader {

struct Screen {
  int width = 0;
  int height = 0;
};

// Состояние загрузчика — для меню и Lua API.
bool ready();          // движок найден, якоря перехвачены
Screen screen();
double frame_time();   // секунды между кадрами
long long frame_count();

JavaVM* vm();

// Размер экрана берётся из androidResize, а если игра его не вызвала —
// из вьюпорта GL при поднятии интерфейса.
void set_screen(int width, int height);

// Отправляет строку в игровой чат так же, как если бы её напечатал игрок:
// через публичный GTASA.t_OnInputEnd(), который сам перекладывает вызов
// на UI-поток. Возвращает false, если активити ещё не поймана
// (до первой отправки чего-либо из чата её объект нам недоступен).
bool send_chat(const std::string& text);
bool can_send_chat();

}  // namespace ag::loader
