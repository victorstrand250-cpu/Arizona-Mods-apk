// SPDX-License-Identifier: GPL-3.0-or-later
#include "gui.h"

#include <GLES3/gl3.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "backends/imgui_impl_opengl3.h"
#include "engine.h"
#include "imgui.h"
#include "imgui_internal.h"
#include "input.h"
#include "loader.h"
#include "log.h"
#include "paths.h"
#include "script/manager.h"

namespace ag::gui {
namespace {

bool g_inited = false;
bool g_menu_open = false;
int g_width = 0;
int g_height = 0;

// Плавающая кнопка вызова меню: на телефоне другого способа нет.
float g_ui_scale = 1.0f;
ImVec2 g_button_pos { 24.0f, 24.0f };
const ImVec2 kButtonSize { 132.0f, 56.0f };
bool g_button_dragging = false;
ImVec2 g_button_grab { 0.0f, 0.0f };
bool g_button_moved = false;
bool g_button_visible = true;

bool g_recreate_device_objects = false;
bool g_show_log = true;
bool g_show_scripts = true;
bool g_show_modules = false;
bool g_log_autoscroll = true;

// ────────────────────────────────────────────── сообщения поверх игры
//
// Скрипт отвечает через log(), а лог-консоль спрятана в меню — со стороны
// это выглядит как «команда не сработала». Поэтому каждое сообщение заодно
// всплывает на экране на несколько секунд.
struct Toast {
  std::string text;
  double until = 0.0;
};

std::mutex g_toast_lock;
std::vector<Toast> g_toasts;
bool g_toasts_enabled = true;

double now_seconds()
{
  using clock = std::chrono::steady_clock;
  static const clock::time_point origin = clock::now();
  return std::chrono::duration<double>(clock::now() - origin).count();
}

// Рисуется поверх всего и без окна: сообщение не должно ни перехватывать
// касания, ни зависеть от того, открыто ли меню.
void draw_toasts()
{
  std::vector<Toast> shown;
  {
    std::lock_guard<std::mutex> guard { g_toast_lock };
    const double t = now_seconds();
    g_toasts.erase(std::remove_if(g_toasts.begin(), g_toasts.end(),
                                  [t](const Toast& x) { return x.until < t; }),
                   g_toasts.end());
    shown = g_toasts;
  }
  if (shown.empty()) {
    return;
  }

  // Слева внизу и без рамки: посреди экрана это мешает игре, а внизу
  // сообщение видно краем глаза и оно ничего не закрывает.
  ImDrawList* dl = ImGui::GetForegroundDrawList();
  const float scale = ui_scale();
  const float pad = 6.0f * scale;
  const float line = ImGui::GetFontSize() + 4.0f * scale;
  const float x = 10.0f * scale;

  float y = static_cast<float>(g_height) - 64.0f * scale -
            line * static_cast<float>(shown.size());
  for (const auto& toast : shown) {
    const ImVec2 size = ImGui::CalcTextSize(toast.text.c_str());
    dl->AddRectFilled(ImVec2 { x - pad * 0.5f, y },
                      ImVec2 { x + size.x + pad, y + line },
                      IM_COL32(10, 12, 16, 150), 4.0f * scale);
    // Подложка тёмная и полупрозрачная, текст с тенью — читается и на
    // светлом небе, и на асфальте.
    dl->AddText(ImVec2 { x + 1.0f, y + 2.0f * scale + 1.0f },
                IM_COL32(0, 0, 0, 180), toast.text.c_str());
    dl->AddText(ImVec2 { x, y + 2.0f * scale },
                IM_COL32(225, 230, 240, 235), toast.text.c_str());
    y += line;
  }
}


// ────────────────────────────────────────────── экранная клавиатура
//
// ImGui на Android сам клавиатуру не поднимает: системную вызывает Java, а
// у игры своя, и до неё из оверлея не дотянуться. Поэтому клавиатура здесь
// своя — обычные кнопки ImGui, которые кладут символы прямо во ввод.
// Появляется, когда активно любое поле ввода, и исчезает, когда ввод
// закончен, так что специально включать её не нужно.

bool g_kbd_shift = false;
bool g_kbd_ru = true;
std::string g_kbd_last_input;
std::string g_kbd_refocus;

const char* const kRowsEn[4] = {
    "1234567890",
    "qwertyuiop",
    "asdfghjkl",
    "zxcvbnm",
};

// Кириллица в UTF-8, по строке на ряд: раскладывается по одному символу
// через разбор UTF-8, а не по байтам.
const char* const kRowsRu[4] = {
    "1234567890",
    "йцукенгшщзхъ",
    "фывапролджэ",
    "ячсмитьбю",
};

// Один символ UTF-8 из строки: возвращает его длину в байтах.
int utf8_len(unsigned char c)
{
  if (c < 0x80) return 1;
  if ((c >> 5) == 0x6) return 2;
  if ((c >> 4) == 0xE) return 3;
  if ((c >> 3) == 0x1E) return 4;
  return 1;
}

// Верхний регистр для одного символа: латиница таблицей, кириллица сдвигом
// на 0x20 внутри своего блока UTF-8.
std::string upper_utf8(const std::string& ch)
{
  if (ch.size() == 1) {
    char c = ch[0];
    if (c >= 'a' && c <= 'z') {
      return std::string(1, static_cast<char>(c - 'a' + 'A'));
    }
    return ch;
  }
  if (ch.size() == 2) {
    const unsigned char b0 = static_cast<unsigned char>(ch[0]);
    const unsigned char b1 = static_cast<unsigned char>(ch[1]);
    // а..я это U+0430..U+044F, А..Я — U+0410..U+042F.
    unsigned int cp = ((b0 & 0x1Fu) << 6) | (b1 & 0x3Fu);
    if (cp >= 0x430 && cp <= 0x44F) {
      cp -= 0x20;
    } else if (cp == 0x451) {  // ё -> Ё
      cp = 0x401;
    } else {
      return ch;
    }
    std::string out;
    out += static_cast<char>(0xC0 | (cp >> 6));
    out += static_cast<char>(0x80 | (cp & 0x3F));
    return out;
  }
  return ch;
}

void kbd_send(const std::string& ch)
{
  ImGuiIO& io = ImGui::GetIO();
  const std::string text = g_kbd_shift ? upper_utf8(ch) : ch;
  io.AddInputCharactersUTF8(text.c_str());
  g_kbd_shift = false;
  g_kbd_refocus = g_kbd_last_input;
}

void kbd_key(ImGuiKey key)
{
  ImGuiIO& io = ImGui::GetIO();
  io.AddKeyEvent(key, true);
  io.AddKeyEvent(key, false);
  g_kbd_refocus = g_kbd_last_input;
}

void draw_keyboard()
{
  ImGuiIO& io = ImGui::GetIO();
  // Пока идёт возврат фокуса, поле на один кадр неактивно — если в этот
  // момент спрятать клавиатуру, она будет мигать на каждой букве.
  if (!io.WantTextInput && g_kbd_refocus.empty()) {
    g_kbd_last_input.clear();
    return;
  }

  const float scale = ui_scale();
  const float kw = 46.0f * scale;
  const float kh = 40.0f * scale;
  const float gap = 4.0f * scale;

  const float width = kw * 12.0f + gap * 13.0f;
  const float height = kh * 5.0f + gap * 7.0f;

  ImGui::SetNextWindowPos(
      ImVec2 { (static_cast<float>(g_width) - width) * 0.5f,
               static_cast<float>(g_height) - height - 12.0f * scale },
      ImGuiCond_Always);
  ImGui::SetNextWindowSize(ImVec2 { width, height }, ImGuiCond_Always);
  ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding,
                      ImVec2 { gap * 1.5f, gap * 1.5f });
  ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2 { gap, gap });

  if (ImGui::Begin("##agkbd", nullptr,
                   ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                       ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoScrollbar |
                       ImGuiWindowFlags_NoNavFocus |
                       ImGuiWindowFlags_NoFocusOnAppearing)) {
    const char* const* rows = g_kbd_ru ? kRowsRu : kRowsEn;

    for (int r = 0; r < 4; ++r) {
      const std::string row = rows[r];
      // Ряды короче первого сдвигаем, чтобы клавиатура не выглядела рваной.
      std::size_t count = 0;
      for (std::size_t i = 0; i < row.size();) {
        i += static_cast<std::size_t>(
            utf8_len(static_cast<unsigned char>(row[i])));
        ++count;
      }
      const float indent =
          (width - gap * 3.0f - (kw + gap) * static_cast<float>(count)) * 0.5f;
      if (indent > 0.0f) {
        ImGui::Dummy(ImVec2 { indent, 1.0f });
        ImGui::SameLine();
      }

      int n = 0;
      for (std::size_t i = 0; i < row.size();) {
        const int len = utf8_len(static_cast<unsigned char>(row[i]));
        std::string ch = row.substr(i, static_cast<std::size_t>(len));
        i += static_cast<std::size_t>(len);

        if (n > 0) {
          ImGui::SameLine();
        }
        ++n;
        const std::string label =
            (g_kbd_shift ? upper_utf8(ch) : ch) + "##k" + std::to_string(r) +
            "_" + std::to_string(n);
        if (ImGui::Button(label.c_str(), ImVec2 { kw, kh })) {
          kbd_send(ch);
        }
      }
    }

    // Нижний ряд: регистр, язык, пробел, точка, стереть, ввод.
    if (ImGui::Button(g_kbd_shift ? "ШИФТ" : "шифт", ImVec2 { kw * 1.6f, kh })) {
      g_kbd_shift = !g_kbd_shift;
    }
    ImGui::SameLine();
    if (ImGui::Button(g_kbd_ru ? "РУС" : "ENG", ImVec2 { kw * 1.4f, kh })) {
      g_kbd_ru = !g_kbd_ru;
    }
    ImGui::SameLine();
    if (ImGui::Button("пробел", ImVec2 { kw * 4.0f, kh })) {
      kbd_send(" ");
    }
    ImGui::SameLine();
    if (ImGui::Button("-", ImVec2 { kw, kh })) {
      kbd_send("-");
    }
    ImGui::SameLine();
    if (ImGui::Button("<-", ImVec2 { kw * 1.6f, kh })) {
      kbd_key(ImGuiKey_Backspace);
    }
    ImGui::SameLine();
    if (ImGui::Button("ввод", ImVec2 { kw * 1.6f, kh })) {
      kbd_key(ImGuiKey_Enter);
    }
  }
  ImGui::End();
  ImGui::PopStyleVar(2);
}

void apply_style(float scale)
{
  ImGui::StyleColorsDark();
  ImGuiStyle& s = ImGui::GetStyle();
  s.WindowRounding = 8.0f;
  s.FrameRounding = 6.0f;
  s.GrabRounding = 6.0f;
  s.ScrollbarRounding = 6.0f;
  s.WindowBorderSize = 1.0f;
  s.FrameBorderSize = 0.0f;
  s.WindowPadding = ImVec2 { 12.0f, 12.0f };
  s.FramePadding = ImVec2 { 10.0f, 8.0f };
  s.ItemSpacing = ImVec2 { 8.0f, 8.0f };
  s.ScrollbarSize = 18.0f;
  s.Colors[ImGuiCol_WindowBg] = ImVec4 { 0.07f, 0.08f, 0.10f, 0.94f };
  s.Colors[ImGuiCol_TitleBgActive] = ImVec4 { 0.14f, 0.36f, 0.55f, 1.00f };
  s.Colors[ImGuiCol_Header] = ImVec4 { 0.14f, 0.36f, 0.55f, 0.70f };
  s.Colors[ImGuiCol_Button] = ImVec4 { 0.14f, 0.32f, 0.48f, 0.85f };
  s.Colors[ImGuiCol_ButtonHovered] = ImVec4 { 0.18f, 0.44f, 0.66f, 1.00f };
  s.Colors[ImGuiCol_ButtonActive] = ImVec4 { 0.22f, 0.52f, 0.78f, 1.00f };
  s.ScaleAllSizes(scale);
}

void load_font(float size_px)
{
  ImGuiIO& io = ImGui::GetIO();

  // В движке нет своего шрифта для нас, поэтому берём системный —
  // он есть на любом Android и содержит кириллицу.
  static const char* kCandidates[] = {
      "/system/fonts/Roboto-Regular.ttf",
      "/system/fonts/NotoSans-Regular.ttf",
      "/system/fonts/DroidSans.ttf",
  };

  ImFontGlyphRangesBuilder builder;
  builder.AddRanges(io.Fonts->GetGlyphRangesDefault());
  builder.AddRanges(io.Fonts->GetGlyphRangesCyrillic());
  static ImVector<ImWchar> ranges;
  ranges.clear();
  builder.BuildRanges(&ranges);

  for (const char* path : kCandidates) {
    std::FILE* f = std::fopen(path, "rb");
    if (f == nullptr) {
      continue;
    }
    std::fclose(f);
    if (io.Fonts->AddFontFromFileTTF(path, size_px, nullptr, ranges.Data) !=
        nullptr) {
      AG_LOGI("шрифт: %s (%.0f px)", path, size_px);
      return;
    }
  }
  io.Fonts->AddFontDefault();
  AG_LOGW("системный шрифт не найден, кириллицы в меню не будет");
}

// --------------------------------------------------------------- окна меню

void draw_button()
{
  ImGuiIO& io = ImGui::GetIO();

  ImGui::SetNextWindowPos(g_button_pos, ImGuiCond_Always);
  ImGui::SetNextWindowSize(kButtonSize, ImGuiCond_Always);
  ImGui::SetNextWindowBgAlpha(0.0f);
  const ImGuiWindowFlags flags =
      ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
      ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoSavedSettings |
      ImGuiWindowFlags_NoFocusOnAppearing | ImGuiWindowFlags_NoBackground |
      ImGuiWindowFlags_NoMove;

  if (ImGui::Begin("##agloader_button", nullptr, flags)) {
    if (ImGui::Button(g_menu_open ? "AGLoader  x" : "AGLoader",
                      ImVec2 { -1.0f, -1.0f })) {
      if (!g_button_moved) {
        g_menu_open = !g_menu_open;
      }
    }

    // Кнопку можно перетаскивать — иначе она перекроет управление игрой.
    if (ImGui::IsItemActive() && io.MouseDown[0]) {
      if (!g_button_dragging) {
        g_button_dragging = true;
        g_button_moved = false;
        g_button_grab = ImVec2 { io.MousePos.x - g_button_pos.x,
                                 io.MousePos.y - g_button_pos.y };
      }
      const ImVec2 want { io.MousePos.x - g_button_grab.x,
                          io.MousePos.y - g_button_grab.y };
      const float dx = want.x - g_button_pos.x;
      const float dy = want.y - g_button_pos.y;
      if ((dx * dx + dy * dy) > 36.0f) {
        g_button_moved = true;
      }
      g_button_pos = want;
      if (g_button_pos.x < 0.0f) g_button_pos.x = 0.0f;
      if (g_button_pos.y < 0.0f) g_button_pos.y = 0.0f;
      if (g_width > 0 && g_button_pos.x > g_width - kButtonSize.x) {
        g_button_pos.x = static_cast<float>(g_width) - kButtonSize.x;
      }
      if (g_height > 0 && g_button_pos.y > g_height - kButtonSize.y) {
        g_button_pos.y = static_cast<float>(g_height) - kButtonSize.y;
      }
    } else if (!io.MouseDown[0]) {
      g_button_dragging = false;
    }
  }
  ImGui::End();
}

void draw_scripts_window()
{
  ImGui::SetNextWindowSize(ImVec2 { 560.0f, 380.0f }, ImGuiCond_FirstUseEver);
  ImGui::SetNextWindowPos(ImVec2 { 180.0f, 100.0f }, ImGuiCond_FirstUseEver);
  if (!ImGui::Begin("Скрипты", &g_show_scripts)) {
    ImGui::End();
    return;
  }

  if (ImGui::Button("Перезагрузить все")) {
    script::manager::request_reload();
  }
  ImGui::SameLine();
  ImGui::TextDisabled("%s", paths::scripts().c_str());

  ImGui::Separator();

  const auto scripts = script::manager::list();
  if (scripts.empty()) {
    ImGui::TextWrapped(
        "Ни одного .lua не найдено.\nПоложите скрипты в:\n%s",
        paths::scripts().c_str());
  }

  for (const auto& s : scripts) {
    ImGui::PushID(s.id);

    const char* state = "?";
    ImVec4 color { 0.8f, 0.8f, 0.8f, 1.0f };
    switch (s.state) {
      case script::manager::State::Loading:
        state = "загрузка"; color = ImVec4 { 0.7f, 0.7f, 0.7f, 1.0f }; break;
      case script::manager::State::Running:
        state = "работает"; color = ImVec4 { 0.4f, 0.9f, 0.4f, 1.0f }; break;
      case script::manager::State::Sleeping:
        state = "ожидание"; color = ImVec4 { 0.5f, 0.8f, 1.0f, 1.0f }; break;
      case script::manager::State::Finished:
        state = "завершён"; color = ImVec4 { 0.6f, 0.6f, 0.6f, 1.0f }; break;
      case script::manager::State::Failed:
        state = "ОШИБКА"; color = ImVec4 { 1.0f, 0.4f, 0.4f, 1.0f }; break;
      case script::manager::State::Terminated:
        state = "остановлен"; color = ImVec4 { 0.9f, 0.7f, 0.3f, 1.0f }; break;
    }

    const std::string title = s.name.empty() ? s.file : s.name;
    if (ImGui::TreeNode("node", "%s", title.c_str())) {
      ImGui::TextColored(color, "%s", state);
      if (!s.author.empty()) {
        ImGui::Text("автор: %s", s.author.c_str());
      }
      if (!s.version.empty()) {
        ImGui::Text("версия: %s", s.version.c_str());
      }
      ImGui::Text("файл: %s", s.file.c_str());
      ImGui::Text("кадр: %.3f мс", s.cpu_ms);
      if (!s.error.empty()) {
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4 { 1.0f, 0.45f, 0.45f, 1.0f });
        ImGui::TextWrapped("%s", s.error.c_str());
        ImGui::PopStyleColor();
      }
      if (ImGui::Button("Перезапустить")) {
        script::manager::restart(s.id);
      }
      ImGui::SameLine();
      if (ImGui::Button("Остановить")) {
        script::manager::terminate(s.id);
      }
      ImGui::TreePop();
    } else {
      ImGui::SameLine();
      ImGui::TextColored(color, "[%s]", state);
    }

    ImGui::PopID();
  }

  ImGui::End();
}

void draw_log_window()
{
  ImGui::SetNextWindowSize(ImVec2 { 720.0f, 320.0f }, ImGuiCond_FirstUseEver);
  ImGui::SetNextWindowPos(ImVec2 { 180.0f, 500.0f }, ImGuiCond_FirstUseEver);
  if (!ImGui::Begin("Лог", &g_show_log)) {
    ImGui::End();
    return;
  }

  if (ImGui::Button("Очистить")) {
    log::clear_tail();
  }
  ImGui::SameLine();
  ImGui::Checkbox("Автопрокрутка", &g_log_autoscroll);
  ImGui::SameLine();
  ImGui::TextDisabled("%s/agloader.log", paths::logs().c_str());

  ImGui::Separator();
  ImGui::BeginChild("##log_scroll", ImVec2 { 0.0f, 0.0f }, ImGuiChildFlags_None,
                    ImGuiWindowFlags_HorizontalScrollbar);

  for (const auto& line : log::tail(400)) {
    ImVec4 color { 0.85f, 0.85f, 0.85f, 1.0f };
    switch (line.lvl) {
      case log::Level::Debug: color = ImVec4 { 0.6f, 0.6f, 0.6f, 1.0f }; break;
      case log::Level::Info: color = ImVec4 { 0.85f, 0.85f, 0.85f, 1.0f }; break;
      case log::Level::Warn: color = ImVec4 { 1.0f, 0.85f, 0.4f, 1.0f }; break;
      case log::Level::Error: color = ImVec4 { 1.0f, 0.45f, 0.45f, 1.0f }; break;
      case log::Level::Script: color = ImVec4 { 0.55f, 0.85f, 1.0f, 1.0f }; break;
    }
    ImGui::TextColored(color, "%s", line.text.c_str());
  }

  if (g_log_autoscroll && ImGui::GetScrollY() >= ImGui::GetScrollMaxY() - 1.0f) {
    ImGui::SetScrollHereY(1.0f);
  }
  ImGui::EndChild();
  ImGui::End();
}

void draw_modules_window()
{
  ImGui::SetNextWindowSize(ImVec2 { 720.0f, 380.0f }, ImGuiCond_FirstUseEver);
  if (!ImGui::Begin("Модули", &g_show_modules)) {
    ImGui::End();
    return;
  }

  ImGui::TextWrapped(
      "Адреса нужны для memory.* и ffi. База движка меняется при каждом "
      "запуске (ASLR), поэтому смещения считайте от неё.");
  ImGui::Separator();

  if (ImGui::BeginTable("##modules", 3,
                        ImGuiTableFlags_RowBg | ImGuiTableFlags_Borders |
                            ImGuiTableFlags_ScrollY)) {
    ImGui::TableSetupColumn("модуль");
    ImGui::TableSetupColumn("база");
    ImGui::TableSetupColumn("размер");
    ImGui::TableHeadersRow();

    for (const auto& m : engine::modules()) {
      const std::size_t slash = m.path.find_last_of('/');
      const std::string file =
          slash == std::string::npos ? m.path : m.path.substr(slash + 1);
      if (file.size() < 4 || file.compare(file.size() - 3, 3, ".so") != 0) {
        continue;
      }
      ImGui::TableNextRow();
      ImGui::TableNextColumn();
      ImGui::TextUnformatted(file.c_str());
      ImGui::TableNextColumn();
      ImGui::Text("0x%llx", static_cast<unsigned long long>(m.base));
      ImGui::TableNextColumn();
      ImGui::Text("%llu КБ",
                  static_cast<unsigned long long>((m.end - m.base) / 1024));
    }
    ImGui::EndTable();
  }

  ImGui::End();
}

void draw_main_window()
{
  ImGui::SetNextWindowSize(ImVec2 { 460.0f, 300.0f }, ImGuiCond_FirstUseEver);
  ImGui::SetNextWindowPos(ImVec2 { 180.0f, 100.0f }, ImGuiCond_FirstUseEver);

  if (!ImGui::Begin("AGLoader " AGLOADER_VERSION, &g_menu_open)) {
    ImGui::End();
    return;
  }

  const ImGuiIO& io = ImGui::GetIO();
  ImGui::Text("FPS: %.0f  (%.2f мс)", io.Framerate, 1000.0f / io.Framerate);
  ImGui::Text("Экран: %dx%d", g_width, g_height);
  ImGui::Text("Кадров: %lld", loader::frame_count());
  ImGui::Separator();
  ImGui::Text("Пакет: %s", paths::package().c_str());
  ImGui::Text("Движок: 0x%llx (%zu КБ)",
              static_cast<unsigned long long>(engine::client_base()),
              engine::client_size() / 1024);
  ImGui::Text("Скриптов активно: %d", script::manager::running_count());
  ImGui::Separator();

  ImGui::Checkbox("Скрипты", &g_show_scripts);
  ImGui::SameLine();
  ImGui::Checkbox("Лог", &g_show_log);
  ImGui::SameLine();
  ImGui::Checkbox("Модули", &g_show_modules);

  if (ImGui::Checkbox("Показывать кнопку на экране", &g_button_visible) &&
      !g_button_visible) {
    AG_LOGI("кнопка скрыта — меню открывается командой /agloader");
  }
  ImGui::Checkbox("Ответы скриптов поверх игры", &g_toasts_enabled);
  ImGui::TextDisabled("Меню также открывается командой /agloader");

  if (ImGui::Button("Перезагрузить скрипты", ImVec2 { -1.0f, 0.0f })) {
    script::manager::request_reload();
  }

  ImGui::End();
}

}  // namespace

float ui_scale() { return g_ui_scale; }

bool init()
{
  if (g_inited) {
    return true;
  }

  IMGUI_CHECKVERSION();
  if (ImGui::CreateContext() == nullptr) {
    AG_LOGE("ImGui::CreateContext вернул null");
    return false;
  }

  ImGuiIO& io = ImGui::GetIO();
  io.IniFilename = nullptr;  // не пишем imgui.ini в каталог игры
  io.LogFilename = nullptr;
  io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
  io.MouseDrawCursor = false;

  // Экран телефона: если androidResize ещё не пришёл, берём вьюпорт GL.
  if (g_width <= 0 || g_height <= 0) {
    GLint vp[4] = {};
    glGetIntegerv(GL_VIEWPORT, vp);
    g_width = vp[2];
    g_height = vp[3];
  }
  if (g_width <= 0 || g_height <= 0) {
    g_width = 1280;
    g_height = 720;
  }
  // androidResize игра вызывает не всегда — размер, добытый из вьюпорта,
  // публикуем сами, иначе getScreenSize() в скриптах вернёт 0x0.
  loader::set_screen(g_width, g_height);

  // На 1080p-телефоне интерфейс в 1:1 нечитаем — масштабируем по высоте.
  const float scale = g_height > 0 ? static_cast<float>(g_height) / 720.0f : 1.0f;
  const float ui_scale = scale < 1.0f ? 1.0f : (scale > 3.0f ? 3.0f : scale);
  apply_style(ui_scale);
  load_font(18.0f * ui_scale);

  if (!ImGui_ImplOpenGL3_Init("#version 300 es")) {
    AG_LOGE("ImGui_ImplOpenGL3_Init не удался");
    ImGui::DestroyContext();
    return false;
  }

  g_button_pos = ImVec2 { 24.0f * ui_scale, 24.0f * ui_scale };
  g_ui_scale = ui_scale;
  g_inited = true;
  AG_LOGI("интерфейс поднят: %dx%d, масштаб %.2f", g_width, g_height, ui_scale);
  return true;
}

void shutdown()
{
  if (!g_inited) {
    return;
  }
  ImGui_ImplOpenGL3_Shutdown();
  ImGui::DestroyContext();
  g_inited = false;
}

bool initialized() { return g_inited; }

void on_resize(int width, int height)
{
  if (width > 0 && height > 0) {
    g_width = width;
    g_height = height;
    loader::set_screen(width, height);
  }
}

void on_context_maybe_lost() { g_recreate_device_objects = true; }

void render(double dt)
{
  if (!g_inited) {
    return;
  }

  if (g_recreate_device_objects) {
    // Мы на GL-потоке: старые объекты можно снести, а NewFrame создаст их
    // заново под текущий контекст.
    g_recreate_device_objects = false;
    ImGui_ImplOpenGL3_DestroyDeviceObjects();
    AG_LOGI("объекты GL пересозданы после возврата из паузы");
  }

  ImGuiIO& io = ImGui::GetIO();
  io.DisplaySize = ImVec2 { static_cast<float>(g_width),
                            static_cast<float>(g_height) };
  io.DeltaTime = dt > 0.0 ? static_cast<float>(dt) : 1.0f / 60.0f;

  float mx = 0.0f;
  float my = 0.0f;
  bool down = false;
  input::mouse_state(&mx, &my, &down);
  io.AddMousePosEvent(mx, my);
  io.AddMouseButtonEvent(0, down);

  ImGui_ImplOpenGL3_NewFrame();
  ImGui::NewFrame();

  draw_toasts();

  if (g_button_visible) {
    draw_button();
  }
  if (g_menu_open) {
    draw_main_window();
    if (g_show_scripts) {
      draw_scripts_window();
    }
    if (g_show_log) {
      draw_log_window();
    }
    if (g_show_modules) {
      draw_modules_window();
    }
  }

  script::manager::on_imgui();

  // После скриптов: клавиатура нужна и их полям ввода, и она должна
  // лежать поверх окна, в котором это поле.
  draw_keyboard();

  ImGui::Render();
  ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
}

bool hit_test(float x, float y)
{
  if (!g_inited) {
    return false;
  }

  ImGuiContext* ctx = ImGui::GetCurrentContext();
  if (ctx == nullptr) {
    return false;
  }

  // Проверяем прямоугольники окон прошлого кадра: тач приходит между кадрами,
  // и это единственное согласованное состояние на данный момент.
  for (int i = ctx->Windows.Size - 1; i >= 0; --i) {
    ImGuiWindow* w = ctx->Windows[i];
    if (w == nullptr || !w->WasActive || w->Hidden) {
      continue;
    }
    if ((w->Flags & ImGuiWindowFlags_ChildWindow) != 0) {
      continue;
    }
    const ImVec2 lo = w->Pos;
    const ImVec2 hi { w->Pos.x + w->Size.x, w->Pos.y + w->Size.y };
    if (x >= lo.x && x <= hi.x && y >= lo.y && y <= hi.y) {
      return true;
    }
  }
  return false;
}

void notify(const char* text, double seconds)
{
  if (text == nullptr || *text == '\0' || !g_toasts_enabled) {
    return;
  }
  std::lock_guard<std::mutex> guard { g_toast_lock };
  // Больше четырёх строк на экране — это уже не подсказка, а помеха.
  if (g_toasts.size() >= 4) {
    g_toasts.erase(g_toasts.begin());
  }
  g_toasts.push_back(Toast { text, now_seconds() + seconds });
}

void keyboard_note_input(const char* label)
{
  if (label != nullptr) {
    g_kbd_last_input = label;
  }
}

bool keyboard_take_refocus(const char* label)
{
  if (label == nullptr || g_kbd_refocus.empty() || g_kbd_refocus != label) {
    return false;
  }
  g_kbd_refocus.clear();
  return true;
}

bool notifications_enabled() { return g_toasts_enabled; }

void set_notifications_enabled(bool on)
{
  g_toasts_enabled = on;
  if (!on) {
    std::lock_guard<std::mutex> guard { g_toast_lock };
    g_toasts.clear();
  }
}

bool menu_open() { return g_menu_open; }
void set_menu_open(bool open) { g_menu_open = open; }
bool button_visible() { return g_button_visible; }
void set_button_visible(bool visible) { g_button_visible = visible; }

}  // namespace ag::gui
