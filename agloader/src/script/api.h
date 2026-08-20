// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

struct lua_State;

namespace ag::script::api {

// Регистрирует все модули API в состоянии скрипта.
void open_all(lua_State* L);

void open_core(lua_State* L);
void open_memory(lua_State* L);
void open_imgui(lua_State* L);

// imgui.* можно звать только внутри onImgui, между NewFrame и Render.
// Менеджер выставляет флаг на время вызова событий.
void imgui_set_frame_active(bool active);
bool imgui_frame_active();

// Закрывает окна/группы, которые скрипт открыл, но не закрыл (например, если
// он упал между Begin и End). Без этого одна ошибка в скрипте ломает весь кадр.
void imgui_unwind();

}  // namespace ag::script::api
