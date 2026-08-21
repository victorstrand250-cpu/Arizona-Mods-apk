// SPDX-License-Identifier: GPL-3.0-or-later
//
// imgui.* — рисование интерфейса из скриптов.
//
// Биндинги сделаны в «луашном» стиле значение-туда-значение-обратно:
//     changed, value = imgui.Checkbox('вкл', value)
// Так не нужны ffi-указатели, как в mimgui, и скрипт остаётся читаемым.
//
// Все функции доступны только внутри onImgui. Открытые скриптом окна
// автоматически закрываются, если он упал (см. imgui_unwind).
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "imgui.h"
#include "lua.hpp"
#include "script/api.h"

namespace ag::script::api {
namespace {

bool g_frame_active = false;

// Что именно скрипт открыл — чтобы корректно свернуть при ошибке.
enum class Scope : char {
  kWindow,
  kChild,
  kGroup,
  kTabBar,
  kTabItem,
  kTooltip,
  kTable,
};
std::vector<Scope> g_scopes;

void require_frame(lua_State* L)
{
  if (!g_frame_active) {
    luaL_error(L, "imgui: рисовать можно только внутри onImgui");
  }
}

ImVec4 color_at(lua_State* L, int idx)
{
  return ImVec4 { static_cast<float>(luaL_checknumber(L, idx)),
                  static_cast<float>(luaL_checknumber(L, idx + 1)),
                  static_cast<float>(luaL_checknumber(L, idx + 2)),
                  static_cast<float>(luaL_optnumber(L, idx + 3, 1.0)) };
}

ImVec2 vec2_at(lua_State* L, int idx, float dx = 0.0f, float dy = 0.0f)
{
  return ImVec2 { static_cast<float>(luaL_optnumber(L, idx, dx)),
                  static_cast<float>(luaL_optnumber(L, idx + 1, dy)) };
}

// ------------------------------------------------------------------- окна

int l_begin(lua_State* L)
{
  require_frame(L);
  const char* name = luaL_checkstring(L, 1);
  const bool closable = !lua_isnoneornil(L, 2);
  bool open = closable ? (lua_toboolean(L, 2) != 0) : true;
  const int flags = static_cast<int>(luaL_optinteger(L, 3, 0));

  const bool visible = ImGui::Begin(name, closable ? &open : nullptr, flags);
  g_scopes.push_back(Scope::kWindow);

  lua_pushboolean(L, visible ? 1 : 0);
  lua_pushboolean(L, open ? 1 : 0);
  return 2;
}

int l_end(lua_State* L)
{
  require_frame(L);
  if (g_scopes.empty() || g_scopes.back() != Scope::kWindow) {
    luaL_error(L, "imgui.End без парного imgui.Begin");
  }
  g_scopes.pop_back();
  ImGui::End();
  return 0;
}

int l_begin_child(lua_State* L)
{
  require_frame(L);
  const char* id = luaL_checkstring(L, 1);
  const ImVec2 size = vec2_at(L, 2);
  const bool border = lua_toboolean(L, 4) != 0;
  const bool visible = ImGui::BeginChild(
      id, size, border ? ImGuiChildFlags_Borders : ImGuiChildFlags_None);
  g_scopes.push_back(Scope::kChild);
  lua_pushboolean(L, visible ? 1 : 0);
  return 1;
}

int l_end_child(lua_State* L)
{
  require_frame(L);
  if (g_scopes.empty() || g_scopes.back() != Scope::kChild) {
    luaL_error(L, "imgui.EndChild без парного imgui.BeginChild");
  }
  g_scopes.pop_back();
  ImGui::EndChild();
  return 0;
}

int l_set_next_window_pos(lua_State* L)
{
  require_frame(L);
  ImGui::SetNextWindowPos(vec2_at(L, 1),
                          static_cast<int>(luaL_optinteger(L, 3, ImGuiCond_Once)));
  return 0;
}

int l_set_next_window_size(lua_State* L)
{
  require_frame(L);
  ImGui::SetNextWindowSize(vec2_at(L, 1),
                           static_cast<int>(luaL_optinteger(L, 3, ImGuiCond_Once)));
  return 0;
}

int l_get_window_size(lua_State* L)
{
  require_frame(L);
  const ImVec2 s = ImGui::GetWindowSize();
  lua_pushnumber(L, s.x);
  lua_pushnumber(L, s.y);
  return 2;
}

int l_get_window_pos(lua_State* L)
{
  require_frame(L);
  const ImVec2 p = ImGui::GetWindowPos();
  lua_pushnumber(L, p.x);
  lua_pushnumber(L, p.y);
  return 2;
}

// ------------------------------------------------------------------ текст

int l_text(lua_State* L)
{
  require_frame(L);
  ImGui::TextUnformatted(luaL_checkstring(L, 1));
  return 0;
}

int l_text_colored(lua_State* L)
{
  require_frame(L);
  const char* s = luaL_checkstring(L, 1);
  ImGui::TextColored(color_at(L, 2), "%s", s);
  return 0;
}

int l_text_disabled(lua_State* L)
{
  require_frame(L);
  ImGui::TextDisabled("%s", luaL_checkstring(L, 1));
  return 0;
}

int l_text_wrapped(lua_State* L)
{
  require_frame(L);
  ImGui::TextWrapped("%s", luaL_checkstring(L, 1));
  return 0;
}

int l_bullet_text(lua_State* L)
{
  require_frame(L);
  ImGui::BulletText("%s", luaL_checkstring(L, 1));
  return 0;
}

// --------------------------------------------------------------- виджеты

int l_button(lua_State* L)
{
  require_frame(L);
  const char* label = luaL_checkstring(L, 1);
  lua_pushboolean(L, ImGui::Button(label, vec2_at(L, 2)) ? 1 : 0);
  return 1;
}

int l_small_button(lua_State* L)
{
  require_frame(L);
  lua_pushboolean(L, ImGui::SmallButton(luaL_checkstring(L, 1)) ? 1 : 0);
  return 1;
}

int l_checkbox(lua_State* L)
{
  require_frame(L);
  const char* label = luaL_checkstring(L, 1);
  bool value = lua_toboolean(L, 2) != 0;
  const bool changed = ImGui::Checkbox(label, &value);
  lua_pushboolean(L, changed ? 1 : 0);
  lua_pushboolean(L, value ? 1 : 0);
  return 2;
}

int l_radio_button(lua_State* L)
{
  require_frame(L);
  const char* label = luaL_checkstring(L, 1);
  const bool active = lua_toboolean(L, 2) != 0;
  lua_pushboolean(L, ImGui::RadioButton(label, active) ? 1 : 0);
  return 1;
}

int l_slider_float(lua_State* L)
{
  require_frame(L);
  const char* label = luaL_checkstring(L, 1);
  float value = static_cast<float>(luaL_checknumber(L, 2));
  const float lo = static_cast<float>(luaL_checknumber(L, 3));
  const float hi = static_cast<float>(luaL_checknumber(L, 4));
  const char* fmt = luaL_optstring(L, 5, "%.3f");
  const bool changed = ImGui::SliderFloat(label, &value, lo, hi, fmt);
  lua_pushboolean(L, changed ? 1 : 0);
  lua_pushnumber(L, value);
  return 2;
}

int l_slider_int(lua_State* L)
{
  require_frame(L);
  const char* label = luaL_checkstring(L, 1);
  int value = static_cast<int>(luaL_checkinteger(L, 2));
  const int lo = static_cast<int>(luaL_checkinteger(L, 3));
  const int hi = static_cast<int>(luaL_checkinteger(L, 4));
  const char* fmt = luaL_optstring(L, 5, "%d");
  const bool changed = ImGui::SliderInt(label, &value, lo, hi, fmt);
  lua_pushboolean(L, changed ? 1 : 0);
  lua_pushinteger(L, value);
  return 2;
}

int l_drag_float(lua_State* L)
{
  require_frame(L);
  const char* label = luaL_checkstring(L, 1);
  float value = static_cast<float>(luaL_checknumber(L, 2));
  const float speed = static_cast<float>(luaL_optnumber(L, 3, 1.0));
  const float lo = static_cast<float>(luaL_optnumber(L, 4, 0.0));
  const float hi = static_cast<float>(luaL_optnumber(L, 5, 0.0));
  const bool changed = ImGui::DragFloat(label, &value, speed, lo, hi);
  lua_pushboolean(L, changed ? 1 : 0);
  lua_pushnumber(L, value);
  return 2;
}

int l_drag_int(lua_State* L)
{
  require_frame(L);
  const char* label = luaL_checkstring(L, 1);
  int value = static_cast<int>(luaL_checkinteger(L, 2));
  const float speed = static_cast<float>(luaL_optnumber(L, 3, 1.0));
  const int lo = static_cast<int>(luaL_optinteger(L, 4, 0));
  const int hi = static_cast<int>(luaL_optinteger(L, 5, 0));
  const bool changed = ImGui::DragInt(label, &value, speed, lo, hi);
  lua_pushboolean(L, changed ? 1 : 0);
  lua_pushinteger(L, value);
  return 2;
}

int l_input_text(lua_State* L)
{
  require_frame(L);
  const char* label = luaL_checkstring(L, 1);
  const char* initial = luaL_optstring(L, 2, "");
  const lua_Integer cap = luaL_optinteger(L, 3, 256);

  std::vector<char> buf(static_cast<std::size_t>(cap > 8 ? cap : 8), '\0');
  std::snprintf(buf.data(), buf.size(), "%s", initial);
  const bool changed = ImGui::InputText(label, buf.data(), buf.size());

  lua_pushboolean(L, changed ? 1 : 0);
  lua_pushstring(L, buf.data());
  return 2;
}

int l_input_float(lua_State* L)
{
  require_frame(L);
  const char* label = luaL_checkstring(L, 1);
  float value = static_cast<float>(luaL_checknumber(L, 2));
  const bool changed = ImGui::InputFloat(label, &value);
  lua_pushboolean(L, changed ? 1 : 0);
  lua_pushnumber(L, value);
  return 2;
}

int l_input_int(lua_State* L)
{
  require_frame(L);
  const char* label = luaL_checkstring(L, 1);
  int value = static_cast<int>(luaL_checkinteger(L, 2));
  const bool changed = ImGui::InputInt(label, &value,
                                      static_cast<int>(luaL_optinteger(L, 3, 1)));
  lua_pushboolean(L, changed ? 1 : 0);
  lua_pushinteger(L, value);
  return 2;
}

int l_color_edit4(lua_State* L)
{
  require_frame(L);
  const char* label = luaL_checkstring(L, 1);
  float rgba[4] = { static_cast<float>(luaL_checknumber(L, 2)),
                    static_cast<float>(luaL_checknumber(L, 3)),
                    static_cast<float>(luaL_checknumber(L, 4)),
                    static_cast<float>(luaL_optnumber(L, 5, 1.0)) };
  const int flags = static_cast<int>(luaL_optinteger(L, 6, 0));
  const bool changed = ImGui::ColorEdit4(label, rgba, flags);
  lua_pushboolean(L, changed ? 1 : 0);
  for (float v : rgba) {
    lua_pushnumber(L, v);
  }
  return 5;
}

int l_get_window_width(lua_State* L)
{
  require_frame(L);
  lua_pushnumber(L, ImGui::GetWindowWidth());
  return 1;
}

int l_color_edit3(lua_State* L)
{
  require_frame(L);
  const char* label = luaL_checkstring(L, 1);
  float rgb[3] = { static_cast<float>(luaL_checknumber(L, 2)),
                   static_cast<float>(luaL_checknumber(L, 3)),
                   static_cast<float>(luaL_checknumber(L, 4)) };
  const bool changed = ImGui::ColorEdit3(label, rgb);
  lua_pushboolean(L, changed ? 1 : 0);
  lua_pushnumber(L, rgb[0]);
  lua_pushnumber(L, rgb[1]);
  lua_pushnumber(L, rgb[2]);
  return 4;
}

int l_progress_bar(lua_State* L)
{
  require_frame(L);
  const float fraction = static_cast<float>(luaL_checknumber(L, 1));
  ImGui::ProgressBar(fraction, vec2_at(L, 2, -1.0f, 0.0f),
                     luaL_optstring(L, 4, nullptr));
  return 0;
}

int l_combo(lua_State* L)
{
  require_frame(L);
  const char* label = luaL_checkstring(L, 1);
  int current = static_cast<int>(luaL_checkinteger(L, 2));  // 1-based
  luaL_checktype(L, 3, LUA_TTABLE);

  std::vector<std::string> items;
  const int n = static_cast<int>(lua_objlen(L, 3));
  items.reserve(static_cast<std::size_t>(n));
  for (int i = 1; i <= n; ++i) {
    lua_rawgeti(L, 3, i);
    const char* s = lua_tostring(L, -1);
    items.emplace_back(s != nullptr ? s : "");
    lua_pop(L, 1);
  }

  std::vector<const char*> ptrs;
  ptrs.reserve(items.size());
  for (const auto& s : items) {
    ptrs.push_back(s.c_str());
  }

  int idx = current - 1;
  if (idx < 0) idx = 0;
  if (n > 0 && idx >= n) idx = n - 1;

  const bool changed =
      n > 0 && ImGui::Combo(label, &idx, ptrs.data(), static_cast<int>(ptrs.size()));

  lua_pushboolean(L, changed ? 1 : 0);
  lua_pushinteger(L, idx + 1);
  return 2;
}

// ------------------------------------------------------------- компоновка

int l_separator(lua_State* L)
{
  require_frame(L);
  ImGui::Separator();
  return 0;
}

int l_same_line(lua_State* L)
{
  require_frame(L);
  ImGui::SameLine(static_cast<float>(luaL_optnumber(L, 1, 0.0)),
                  static_cast<float>(luaL_optnumber(L, 2, -1.0)));
  return 0;
}

// Без этого подпись слева и виджет справа стоят на разной высоте: текст
// рисуется по своей базовой линии, а поле — с рамочными отступами.
int l_align_text_to_frame_padding(lua_State* L)
{
  require_frame(L);
  ImGui::AlignTextToFramePadding();
  return 0;
}

int l_set_next_item_width(lua_State* L)
{
  require_frame(L);
  ImGui::SetNextItemWidth(static_cast<float>(luaL_checknumber(L, 1)));
  return 0;
}

int l_spacing(lua_State* L)
{
  require_frame(L);
  ImGui::Spacing();
  return 0;
}

int l_new_line(lua_State* L)
{
  require_frame(L);
  ImGui::NewLine();
  return 0;
}

int l_dummy(lua_State* L)
{
  require_frame(L);
  ImGui::Dummy(vec2_at(L, 1));
  return 0;
}

int l_indent(lua_State* L)
{
  require_frame(L);
  ImGui::Indent(static_cast<float>(luaL_optnumber(L, 1, 0.0)));
  return 0;
}

int l_unindent(lua_State* L)
{
  require_frame(L);
  ImGui::Unindent(static_cast<float>(luaL_optnumber(L, 1, 0.0)));
  return 0;
}

int l_begin_group(lua_State* L)
{
  require_frame(L);
  ImGui::BeginGroup();
  g_scopes.push_back(Scope::kGroup);
  return 0;
}

int l_end_group(lua_State* L)
{
  require_frame(L);
  if (g_scopes.empty() || g_scopes.back() != Scope::kGroup) {
    luaL_error(L, "imgui.EndGroup без парного imgui.BeginGroup");
  }
  g_scopes.pop_back();
  ImGui::EndGroup();
  return 0;
}

int l_push_item_width(lua_State* L)
{
  require_frame(L);
  ImGui::PushItemWidth(static_cast<float>(luaL_checknumber(L, 1)));
  return 0;
}

int l_pop_item_width(lua_State* L)
{
  require_frame(L);
  ImGui::PopItemWidth();
  return 0;
}

// ------------------------------------------------------- деревья и вкладки

int l_collapsing_header(lua_State* L)
{
  require_frame(L);
  lua_pushboolean(L, ImGui::CollapsingHeader(luaL_checkstring(L, 1)) ? 1 : 0);
  return 1;
}

int l_begin_tab_bar(lua_State* L)
{
  require_frame(L);
  const bool ok = ImGui::BeginTabBar(luaL_checkstring(L, 1));
  if (ok) {
    g_scopes.push_back(Scope::kTabBar);
  }
  lua_pushboolean(L, ok ? 1 : 0);
  return 1;
}

int l_end_tab_bar(lua_State* L)
{
  require_frame(L);
  if (g_scopes.empty() || g_scopes.back() != Scope::kTabBar) {
    luaL_error(L, "imgui.EndTabBar без парного imgui.BeginTabBar");
  }
  g_scopes.pop_back();
  ImGui::EndTabBar();
  return 0;
}

int l_begin_tab_item(lua_State* L)
{
  require_frame(L);
  const bool ok = ImGui::BeginTabItem(luaL_checkstring(L, 1));
  if (ok) {
    g_scopes.push_back(Scope::kTabItem);
  }
  lua_pushboolean(L, ok ? 1 : 0);
  return 1;
}

int l_end_tab_item(lua_State* L)
{
  require_frame(L);
  if (g_scopes.empty() || g_scopes.back() != Scope::kTabItem) {
    luaL_error(L, "imgui.EndTabItem без парного imgui.BeginTabItem");
  }
  g_scopes.pop_back();
  ImGui::EndTabItem();
  return 0;
}

int l_set_tooltip(lua_State* L)
{
  require_frame(L);
  ImGui::SetTooltip("%s", luaL_checkstring(L, 1));
  return 0;
}

// --------------------------------------------------------------- состояние

int l_is_item_hovered(lua_State* L)
{
  require_frame(L);
  lua_pushboolean(L, ImGui::IsItemHovered() ? 1 : 0);
  return 1;
}

int l_is_item_clicked(lua_State* L)
{
  require_frame(L);
  lua_pushboolean(L, ImGui::IsItemClicked() ? 1 : 0);
  return 1;
}

// Сколько раз скрипт за кадр трогал стек стиля. Если он упадёт между Push и
// Pop, несвёрнутый стек утащит за собой и меню загрузчика, поэтому остаток
// разматывается в конце кадра.
int g_style_colors = 0;
int g_style_vars = 0;

int l_push_style_color(lua_State* L)
{
  require_frame(L);
  const int idx = static_cast<int>(luaL_checkinteger(L, 1));
  ImGui::PushStyleColor(idx, color_at(L, 2));
  ++g_style_colors;
  return 0;
}

// Разово меняет цвет в самом стиле — для скриптов, которые красят интерфейс
// один раз при запуске, а не каждый кадр.
int l_set_style_color(lua_State* L)
{
  const int idx = static_cast<int>(luaL_checkinteger(L, 1));
  if (idx < 0 || idx >= ImGuiCol_COUNT) {
    return 0;
  }
  ImGui::GetStyle().Colors[idx] = color_at(L, 2);
  return 0;
}

int l_push_style_var(lua_State* L)
{
  require_frame(L);
  const int idx = static_cast<int>(luaL_checkinteger(L, 1));
  // Два числа — вектор (отступы), одно — скаляр (скругления, толщина).
  if (lua_isnumber(L, 3)) {
    ImGui::PushStyleVar(idx, ImVec2(static_cast<float>(luaL_checknumber(L, 2)),
                                    static_cast<float>(luaL_checknumber(L, 3))));
  } else {
    ImGui::PushStyleVar(idx, static_cast<float>(luaL_checknumber(L, 2)));
  }
  ++g_style_vars;
  return 0;
}

int l_pop_style_var(lua_State* L)
{
  require_frame(L);
  int n = static_cast<int>(luaL_optinteger(L, 1, 1));
  if (n > g_style_vars) {
    n = g_style_vars;  // не даём скрипту сорвать чужой стиль
  }
  if (n > 0) {
    ImGui::PopStyleVar(n);
    g_style_vars -= n;
  }
  return 0;
}

// Разовая настройка стиля по имени: скругления, отступы, толщина рамок.
int l_set_style(lua_State* L)
{
  const char* name = luaL_checkstring(L, 1);
  const double a = luaL_checknumber(L, 2);
  const double b = luaL_optnumber(L, 3, a);
  ImGuiStyle& st = ImGui::GetStyle();

  const std::string key { name };
  if (key == "WindowRounding")        st.WindowRounding = static_cast<float>(a);
  else if (key == "ChildRounding")    st.ChildRounding = static_cast<float>(a);
  else if (key == "FrameRounding")    st.FrameRounding = static_cast<float>(a);
  else if (key == "PopupRounding")    st.PopupRounding = static_cast<float>(a);
  else if (key == "GrabRounding")     st.GrabRounding = static_cast<float>(a);
  else if (key == "TabRounding")      st.TabRounding = static_cast<float>(a);
  else if (key == "ScrollbarRounding") st.ScrollbarRounding = static_cast<float>(a);
  else if (key == "WindowBorderSize") st.WindowBorderSize = static_cast<float>(a);
  else if (key == "ChildBorderSize")  st.ChildBorderSize = static_cast<float>(a);
  else if (key == "FrameBorderSize")  st.FrameBorderSize = static_cast<float>(a);
  else if (key == "ScrollbarSize")    st.ScrollbarSize = static_cast<float>(a);
  else if (key == "WindowPadding")
    st.WindowPadding = ImVec2(static_cast<float>(a), static_cast<float>(b));
  else if (key == "FramePadding")
    st.FramePadding = ImVec2(static_cast<float>(a), static_cast<float>(b));
  else if (key == "ItemSpacing")
    st.ItemSpacing = ImVec2(static_cast<float>(a), static_cast<float>(b));
  else if (key == "ItemInnerSpacing")
    st.ItemInnerSpacing = ImVec2(static_cast<float>(a), static_cast<float>(b));
  return 0;
}

int l_pop_style_color(lua_State* L)
{
  require_frame(L);
  int n = static_cast<int>(luaL_optinteger(L, 1, 1));
  if (n > g_style_colors) {
    n = g_style_colors;
  }
  if (n > 0) {
    ImGui::PopStyleColor(n);
    g_style_colors -= n;
  }
  return 0;
}

// -------------------------------------------- рисование поверх всего (ESP)

ImU32 packed_color(lua_State* L, int idx)
{
  const ImVec4 c = color_at(L, idx);
  return ImGui::ColorConvertFloat4ToU32(c);
}

int l_draw_line(lua_State* L)
{
  require_frame(L);
  ImGui::GetForegroundDrawList()->AddLine(vec2_at(L, 1), vec2_at(L, 3),
                                          packed_color(L, 5),
                                          static_cast<float>(luaL_optnumber(L, 9, 1.0)));
  return 0;
}

int l_draw_rect(lua_State* L)
{
  require_frame(L);
  ImGui::GetForegroundDrawList()->AddRect(
      vec2_at(L, 1), vec2_at(L, 3), packed_color(L, 5), 0.0f, 0,
      static_cast<float>(luaL_optnumber(L, 9, 1.0)));
  return 0;
}

int l_draw_rect_filled(lua_State* L)
{
  require_frame(L);
  ImGui::GetForegroundDrawList()->AddRectFilled(vec2_at(L, 1), vec2_at(L, 3),
                                                packed_color(L, 5));
  return 0;
}

int l_draw_circle(lua_State* L)
{
  require_frame(L);
  ImGui::GetForegroundDrawList()->AddCircle(
      vec2_at(L, 1), static_cast<float>(luaL_checknumber(L, 3)),
      packed_color(L, 4), 0, static_cast<float>(luaL_optnumber(L, 8, 1.0)));
  return 0;
}

int l_draw_circle_filled(lua_State* L)
{
  require_frame(L);
  ImGui::GetForegroundDrawList()->AddCircleFilled(
      vec2_at(L, 1), static_cast<float>(luaL_checknumber(L, 3)),
      packed_color(L, 4));
  return 0;
}

int l_draw_text(lua_State* L)
{
  require_frame(L);
  const ImVec2 pos = vec2_at(L, 1);
  const char* text = luaL_checkstring(L, 3);
  ImGui::GetForegroundDrawList()->AddText(pos, packed_color(L, 4), text);
  return 0;
}

int l_calc_text_size(lua_State* L)
{
  require_frame(L);
  const ImVec2 s = ImGui::CalcTextSize(luaL_checkstring(L, 1));
  lua_pushnumber(L, s.x);
  lua_pushnumber(L, s.y);
  return 2;
}

const luaL_Reg kFuncs[] = {
    { "Begin", l_begin },
    { "End", l_end },
    { "BeginChild", l_begin_child },
    { "EndChild", l_end_child },
    { "SetNextWindowPos", l_set_next_window_pos },
    { "SetNextWindowSize", l_set_next_window_size },
    { "GetWindowSize", l_get_window_size },
    { "GetWindowPos", l_get_window_pos },
    { "Text", l_text },
    { "TextColored", l_text_colored },
    { "TextDisabled", l_text_disabled },
    { "TextWrapped", l_text_wrapped },
    { "BulletText", l_bullet_text },
    { "Button", l_button },
    { "SmallButton", l_small_button },
    { "Checkbox", l_checkbox },
    { "RadioButton", l_radio_button },
    { "SliderFloat", l_slider_float },
    { "SliderInt", l_slider_int },
    { "DragFloat", l_drag_float },
    { "DragInt", l_drag_int },
    { "InputText", l_input_text },
    { "InputFloat", l_input_float },
    { "InputInt", l_input_int },
    { "ColorEdit3", l_color_edit3 },
    { "ColorEdit4", l_color_edit4 },
    { "GetWindowWidth", l_get_window_width },
    { "SetStyleColor", l_set_style_color },
    { "SetStyle", l_set_style },
    { "PushStyleVar", l_push_style_var },
    { "PopStyleVar", l_pop_style_var },
    { "ProgressBar", l_progress_bar },
    { "Combo", l_combo },
    { "Separator", l_separator },
    { "SameLine", l_same_line },
    { "Spacing", l_spacing },
    { "NewLine", l_new_line },
    { "Dummy", l_dummy },
    { "Indent", l_indent },
    { "Unindent", l_unindent },
    { "BeginGroup", l_begin_group },
    { "EndGroup", l_end_group },
    { "AlignTextToFramePadding", l_align_text_to_frame_padding },
    { "SetNextItemWidth", l_set_next_item_width },
    { "PushItemWidth", l_push_item_width },
    { "PopItemWidth", l_pop_item_width },
    { "CollapsingHeader", l_collapsing_header },
    { "BeginTabBar", l_begin_tab_bar },
    { "EndTabBar", l_end_tab_bar },
    { "BeginTabItem", l_begin_tab_item },
    { "EndTabItem", l_end_tab_item },
    { "SetTooltip", l_set_tooltip },
    { "IsItemHovered", l_is_item_hovered },
    { "IsItemClicked", l_is_item_clicked },
    { "PushStyleColor", l_push_style_color },
    { "PopStyleColor", l_pop_style_color },
    { "DrawLine", l_draw_line },
    { "DrawRect", l_draw_rect },
    { "DrawRectFilled", l_draw_rect_filled },
    { "DrawCircle", l_draw_circle },
    { "DrawCircleFilled", l_draw_circle_filled },
    { "DrawText", l_draw_text },
    { "CalcTextSize", l_calc_text_size },
    { nullptr, nullptr },
};

struct Constant {
  const char* name;
  lua_Integer value;
};

const Constant kConstants[] = {
    { "WindowFlags_NoTitleBar", ImGuiWindowFlags_NoTitleBar },
    { "WindowFlags_NoResize", ImGuiWindowFlags_NoResize },
    { "WindowFlags_NoMove", ImGuiWindowFlags_NoMove },
    { "WindowFlags_NoScrollbar", ImGuiWindowFlags_NoScrollbar },
    { "WindowFlags_NoCollapse", ImGuiWindowFlags_NoCollapse },
    { "WindowFlags_AlwaysAutoResize", ImGuiWindowFlags_AlwaysAutoResize },
    { "WindowFlags_NoBackground", ImGuiWindowFlags_NoBackground },
    { "WindowFlags_NoSavedSettings", ImGuiWindowFlags_NoSavedSettings },
    { "WindowFlags_NoInputs", ImGuiWindowFlags_NoInputs },
    { "Cond_Always", ImGuiCond_Always },
    { "Cond_Once", ImGuiCond_Once },
    { "Cond_FirstUseEver", ImGuiCond_FirstUseEver },
    { "Cond_Appearing", ImGuiCond_Appearing },
    { "Col_Text", ImGuiCol_Text },
    { "Col_TextDisabled", ImGuiCol_TextDisabled },
    { "Col_WindowBg", ImGuiCol_WindowBg },
    { "Col_ChildBg", ImGuiCol_ChildBg },
    { "Col_PopupBg", ImGuiCol_PopupBg },
    { "Col_Border", ImGuiCol_Border },
    { "Col_BorderShadow", ImGuiCol_BorderShadow },
    { "Col_FrameBg", ImGuiCol_FrameBg },
    { "Col_FrameBgHovered", ImGuiCol_FrameBgHovered },
    { "Col_FrameBgActive", ImGuiCol_FrameBgActive },
    { "Col_TitleBg", ImGuiCol_TitleBg },
    { "Col_TitleBgActive", ImGuiCol_TitleBgActive },
    { "Col_TitleBgCollapsed", ImGuiCol_TitleBgCollapsed },
    { "Col_MenuBarBg", ImGuiCol_MenuBarBg },
    { "Col_ScrollbarBg", ImGuiCol_ScrollbarBg },
    { "Col_ScrollbarGrab", ImGuiCol_ScrollbarGrab },
    { "Col_ScrollbarGrabHovered", ImGuiCol_ScrollbarGrabHovered },
    { "Col_ScrollbarGrabActive", ImGuiCol_ScrollbarGrabActive },
    { "Col_CheckMark", ImGuiCol_CheckMark },
    { "Col_SliderGrab", ImGuiCol_SliderGrab },
    { "Col_SliderGrabActive", ImGuiCol_SliderGrabActive },
    { "Col_Button", ImGuiCol_Button },
    { "Col_ButtonHovered", ImGuiCol_ButtonHovered },
    { "Col_ButtonActive", ImGuiCol_ButtonActive },
    { "Col_Header", ImGuiCol_Header },
    { "Col_HeaderHovered", ImGuiCol_HeaderHovered },
    { "Col_HeaderActive", ImGuiCol_HeaderActive },
    { "Col_Separator", ImGuiCol_Separator },
    { "Col_SeparatorHovered", ImGuiCol_SeparatorHovered },
    { "Col_SeparatorActive", ImGuiCol_SeparatorActive },
    { "Col_ResizeGrip", ImGuiCol_ResizeGrip },
    { "Col_ResizeGripHovered", ImGuiCol_ResizeGripHovered },
    { "Col_ResizeGripActive", ImGuiCol_ResizeGripActive },
    { "Col_Tab", ImGuiCol_Tab },
    { "Col_TabHovered", ImGuiCol_TabHovered },
    { "Col_PlotLines", ImGuiCol_PlotLines },
    { "Col_PlotHistogram", ImGuiCol_PlotHistogram },
    { "Col_TableHeaderBg", ImGuiCol_TableHeaderBg },
    { "Col_TableBorderStrong", ImGuiCol_TableBorderStrong },
    { "Col_TableRowBg", ImGuiCol_TableRowBg },
    { "Col_TableRowBgAlt", ImGuiCol_TableRowBgAlt },
    { "Col_TextSelectedBg", ImGuiCol_TextSelectedBg },
    { "Col_DragDropTarget", ImGuiCol_DragDropTarget },
    { "Col_NavWindowingHighlight", ImGuiCol_NavWindowingHighlight },
    { "Col_NavWindowingDimBg", ImGuiCol_NavWindowingDimBg },
    { "Col_ModalWindowDimBg", ImGuiCol_ModalWindowDimBg },
    { "StyleVar_Alpha", ImGuiStyleVar_Alpha },
    { "StyleVar_DisabledAlpha", ImGuiStyleVar_DisabledAlpha },
    { "StyleVar_WindowPadding", ImGuiStyleVar_WindowPadding },
    { "StyleVar_WindowRounding", ImGuiStyleVar_WindowRounding },
    { "StyleVar_WindowBorderSize", ImGuiStyleVar_WindowBorderSize },
    { "StyleVar_ChildRounding", ImGuiStyleVar_ChildRounding },
    { "StyleVar_ChildBorderSize", ImGuiStyleVar_ChildBorderSize },
    { "StyleVar_PopupRounding", ImGuiStyleVar_PopupRounding },
    { "StyleVar_PopupBorderSize", ImGuiStyleVar_PopupBorderSize },
    { "StyleVar_FramePadding", ImGuiStyleVar_FramePadding },
    { "StyleVar_FrameRounding", ImGuiStyleVar_FrameRounding },
    { "StyleVar_FrameBorderSize", ImGuiStyleVar_FrameBorderSize },
    { "StyleVar_ItemSpacing", ImGuiStyleVar_ItemSpacing },
    { "StyleVar_ItemInnerSpacing", ImGuiStyleVar_ItemInnerSpacing },
    { "StyleVar_IndentSpacing", ImGuiStyleVar_IndentSpacing },
    { "StyleVar_ScrollbarSize", ImGuiStyleVar_ScrollbarSize },
    { "StyleVar_ScrollbarRounding", ImGuiStyleVar_ScrollbarRounding },
    { "StyleVar_GrabMinSize", ImGuiStyleVar_GrabMinSize },
    { "StyleVar_GrabRounding", ImGuiStyleVar_GrabRounding },
    { "StyleVar_TabRounding", ImGuiStyleVar_TabRounding },
    { "ColorEditFlags_NoAlpha", ImGuiColorEditFlags_NoAlpha },
    { "ColorEditFlags_NoPicker", ImGuiColorEditFlags_NoPicker },
    { "ColorEditFlags_NoInputs", ImGuiColorEditFlags_NoInputs },
    { "ColorEditFlags_NoTooltip", ImGuiColorEditFlags_NoTooltip },
    { "ColorEditFlags_NoLabel", ImGuiColorEditFlags_NoLabel },
    { "ColorEditFlags_NoSidePreview", ImGuiColorEditFlags_NoSidePreview },
    { "ColorEditFlags_AlphaBar", ImGuiColorEditFlags_AlphaBar },
    { "ColorEditFlags_AlphaPreview", ImGuiColorEditFlags_AlphaPreview },
    { "ColorEditFlags_AlphaPreviewHalf", ImGuiColorEditFlags_AlphaPreviewHalf },
    { "ColorEditFlags_DisplayRGB", ImGuiColorEditFlags_DisplayRGB },
    { "ColorEditFlags_DisplayHSV", ImGuiColorEditFlags_DisplayHSV },
    { "ColorEditFlags_DisplayHex", ImGuiColorEditFlags_DisplayHex },
    { "ColorEditFlags_PickerHueBar", ImGuiColorEditFlags_PickerHueBar },
    { "ColorEditFlags_PickerHueWheel", ImGuiColorEditFlags_PickerHueWheel },
    { nullptr, 0 },
};

}  // namespace

void imgui_set_frame_active(bool active)
{
  g_frame_active = active;
  if (!active) {
    g_scopes.clear();
  }
}

bool imgui_frame_active() { return g_frame_active; }

void imgui_unwind()
{
  // Свернуть в обратном порядке всё, что скрипт открыл и не закрыл.
  while (!g_scopes.empty()) {
    switch (g_scopes.back()) {
      case Scope::kWindow: ImGui::End(); break;
      case Scope::kChild: ImGui::EndChild(); break;
      case Scope::kGroup: ImGui::EndGroup(); break;
      case Scope::kTabBar: ImGui::EndTabBar(); break;
      case Scope::kTabItem: ImGui::EndTabItem(); break;
      case Scope::kTooltip: ImGui::EndTooltip(); break;
      case Scope::kTable: ImGui::EndTable(); break;
    }
    g_scopes.pop_back();
  }

  if (g_style_colors > 0) {
    ImGui::PopStyleColor(g_style_colors);
    g_style_colors = 0;
  }
  if (g_style_vars > 0) {
    ImGui::PopStyleVar(g_style_vars);
    g_style_vars = 0;
  }
}

void open_imgui(lua_State* L)
{
  lua_newtable(L);
  for (const luaL_Reg* r = kFuncs; r->name != nullptr; ++r) {
    lua_pushcfunction(L, r->func);
    lua_setfield(L, -2, r->name);
  }
  for (const Constant* c = kConstants; c->name != nullptr; ++c) {
    lua_pushinteger(L, c->value);
    lua_setfield(L, -2, c->name);
  }
  lua_setglobal(L, "imgui");
}

}  // namespace ag::script::api
