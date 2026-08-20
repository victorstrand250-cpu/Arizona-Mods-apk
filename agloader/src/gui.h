// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

namespace ag::gui {

// Поднимает ImGui и GLES3-бэкенд. Звать только с активным GL-контекстом,
// то есть из перехвата androidStep. Идемпотентна.
bool init();
void shutdown();

bool initialized();

void on_resize(int width, int height);

// Полный кадр интерфейса: служебное меню + onImgui из скриптов.
void render(double dt);

// Попадает ли точка в интерфейс загрузчика (окна ImGui или кнопку меню).
// Используется тач-обработчиком, чтобы решить, поглощать ли событие.
bool hit_test(float x, float y);

bool menu_open();
void set_menu_open(bool open);

}  // namespace ag::gui
