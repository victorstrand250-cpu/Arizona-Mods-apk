// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

namespace ag::input {

// MotionEvent.getActionMasked()
enum Action {
  kDown = 0,
  kUp = 1,
  kMove = 2,
  kCancel = 3,
  kPointerDown = 5,
  kPointerUp = 6,
};

// Возвращает true, если событие поглощено интерфейсом загрузчика
// и передавать его движку не нужно.
bool on_touch(int action, int pointer_id, int x, int y, int x1, int y1, int x2,
              int y2);

// Сбрасывает захват (например, при сворачивании приложения).
void reset();

// Текущие координаты пальца, которым «водят» по меню.
void mouse_state(float* x, float* y, bool* down);

}  // namespace ag::input
