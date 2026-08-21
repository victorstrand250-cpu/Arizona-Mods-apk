// SPDX-License-Identifier: GPL-3.0-or-later
#include "input.h"

#include <atomic>

#include "gui.h"
#include "script/manager.h"

namespace ag::input {
namespace {

// Движок отдаёт координаты только трёх пальцев (id 0..2), см. JNIActivity.
constexpr int kMaxPointers = 3;

struct Pointer {
  int x = 0;
  int y = 0;
  bool down = false;
  bool captured = false;  // палец «принадлежит» меню
};

Pointer g_pointers[kMaxPointers];

// Позиция и состояние виртуальной мыши, которую видит ImGui.
std::atomic<int> g_mouse_x { 0 };
std::atomic<int> g_mouse_y { 0 };
std::atomic<bool> g_mouse_down { false };

int captured_count()
{
  int n = 0;
  for (const auto& p : g_pointers) {
    if (p.captured) {
      ++n;
    }
  }
  return n;
}

void set_mouse(int x, int y, bool down)
{
  g_mouse_x.store(x);
  g_mouse_y.store(y);
  g_mouse_down.store(down);
}

}  // namespace

bool on_touch(int action, int pointer_id, int x, int y, int x1, int y1, int x2,
              int y2)
{
  const int xs[kMaxPointers] = { x, x1, x2 };
  const int ys[kMaxPointers] = { y, y1, y2 };

  for (int i = 0; i < kMaxPointers; ++i) {
    g_pointers[i].x = xs[i];
    g_pointers[i].y = ys[i];
  }

  const bool id_ok = pointer_id >= 0 && pointer_id < kMaxPointers;
  const int px = id_ok ? xs[pointer_id] : 0;
  const int py = id_ok ? ys[pointer_id] : 0;

  bool consumed = false;

  switch (action) {
    case kDown:
    case kPointerDown: {
      if (!id_ok) {
        break;
      }
      g_pointers[pointer_id].down = true;
      if (gui::hit_test(static_cast<float>(px), static_cast<float>(py))) {
        g_pointers[pointer_id].captured = true;
        set_mouse(px, py, true);
        consumed = true;
      }
      break;
    }
    case kMove: {
      // У ACTION_MOVE actionIndex всегда 0, поэтому ориентируемся не на
      // pointer_id, а на то, какой палец мы ранее захватили.
      for (int i = 0; i < kMaxPointers; ++i) {
        if (g_pointers[i].captured) {
          set_mouse(g_pointers[i].x, g_pointers[i].y, true);
          consumed = true;
          break;
        }
      }
      break;
    }
    case kUp:
    case kPointerUp: {
      if (!id_ok) {
        break;
      }
      g_pointers[pointer_id].down = false;
      if (g_pointers[pointer_id].captured) {
        g_pointers[pointer_id].captured = false;
        set_mouse(px, py, false);
        consumed = true;
      }
      if (action == kUp && captured_count() == 0) {
        g_mouse_down.store(false);
      }
      break;
    }
    case kCancel:
    default: {
      reset();
      break;
    }
  }

  // Скрипты видят все касания, включая поглощённые: так onTouch остаётся
  // предсказуемым. Скрипт может поглотить событие, вернув false.
  if (!consumed && script::manager::on_touch(action, pointer_id, px, py)) {
    consumed = true;
  }

  return consumed;
}

void reset()
{
  for (auto& p : g_pointers) {
    p.down = false;
    p.captured = false;
  }
  g_mouse_down.store(false);
}

void mouse_state(float* x, float* y, bool* down)
{
  if (x != nullptr) {
    *x = static_cast<float>(g_mouse_x.load());
  }
  if (y != nullptr) {
    *y = static_cast<float>(g_mouse_y.load());
  }
  if (down != nullptr) {
    *down = g_mouse_down.load();
  }
}

}  // namespace ag::input
