// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <jni.h>

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

}  // namespace ag::loader
