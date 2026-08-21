// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

namespace ag::gui {

// Поднимает ImGui и GLES3-бэкенд. Звать только с активным GL-контекстом,
// то есть из перехвата androidStep. Идемпотентна.
bool init();

// Во сколько раз интерфейс крупнее базового 720p. Размеры, которые скрипт
// задаёт явно (ширина окна, высота кнопки), ImGui не масштабирует, поэтому
// множитель отдаётся в Lua как getUiScale() — аналог MONET_DPI_SCALE.
float ui_scale();
void shutdown();

bool initialized();

void on_resize(int width, int height);

// Приложение вернулось из свёрнутого состояния. JNIGLSurfaceView вызывает
// setPreserveEGLContextOnPause() со значением из настроек, то есть контекст
// GL мог быть потерян, а вместе с ним — шейдеры и текстура шрифта ImGui.
// Пересоздаём их на следующем кадре, уже на GL-потоке.
void on_context_maybe_lost();

// Полный кадр интерфейса: служебное меню + onImgui из скриптов.
void render(double dt);

// Попадает ли точка в интерфейс загрузчика (окна ImGui или кнопку меню).
// Используется тач-обработчиком, чтобы решить, поглощать ли событие.
bool hit_test(float x, float y);

// Сообщение поверх игры на несколько секунд.
//
// Без него ответы скриптов уходили только в лог-консоль внутри меню, и со
// стороны это выглядело так, будто команда не сработала вовсе. Теперь любой
// log() из скрипта заодно всплывает на экране.
void notify(const char* text, double seconds = 3.0);

// Показывать ли всплывающие сообщения. Переключается в меню.
bool notifications_enabled();
void set_notifications_enabled(bool on);

// Экранная клавиатура. ImGui на Android сам ввода не поднимает: системную
// клавиатуру вызывает Java, у игры своя, и до неё из оверлея не дотянуться.
// Поэтому клавиатура нарисована обычными кнопками ImGui.
//
// Нажатие на кнопку клавиатуры — это клик мимо поля ввода, и ImGui снял бы
// с поля фокус. Поэтому поле сообщает о себе, а клавиатура просит вернуть
// ему фокус на следующем кадре.
void keyboard_note_input(const char* label);
bool keyboard_take_refocus(const char* label);

bool menu_open();
void set_menu_open(bool open);

// Плавающую кнопку можно убрать с экрана — тогда меню открывается
// только чат-командой /agloader.
bool button_visible();
void set_button_visible(bool visible);

}  // namespace ag::gui
