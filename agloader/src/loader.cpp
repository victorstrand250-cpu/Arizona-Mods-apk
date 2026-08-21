// SPDX-License-Identifier: GPL-3.0-or-later
//
// Точка входа AGLoader.
//
// Как это работает
// ----------------
// Новый клиент Arizona (libag-client.so) собран stripped: игровых символов нет,
// хукать по именам, как это делает MonetLoader в libGTASA.so, невозможно.
// Единственное, что движок отдаёт наружу, — семь JNI-функций класса
// com.arizonagames.client.game.core.JNILib. На них загрузчик и опирается.
//
// Перехват сделан не инлайн-хуком, а через JNI RegisterNatives: наша библиотека
// грузится из <clinit> JNILib раньше движка, запоминает класс JNILib, дожидается
// появления libag-client.so, резолвит через dlsym оригиналы и перерегистрирует
// нативные методы на свои обёртки. RegisterNatives всегда приоритетнее поиска
// по имени, поэтому механизм не зависит ни от порядка загрузки библиотек,
// ни от версии ART.
//
// Что это даёт:
//   androidStep       — тик кадра на GL-потоке, уже после отрисовки игры,
//                       но до eglSwapBuffers: идеальная точка для оверлея;
//   androidMultiTouch — тач-ввод (можно поглощать, не пропуская в игру);
//   androidResize     — размеры экрана;
//   androidKeyEvent / androidPause / androidResume — события Lua-скриптов.
#include "loader.h"

#include <dlfcn.h>

#include <atomic>
#include <chrono>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

#include "engine.h"
#include "gui.h"
#include "input.h"
#include "log.h"
#include "paths.h"
#include "script/manager.h"

namespace ag::loader {
namespace {

constexpr const char* kJniLibClass = "com/arizonagames/client/game/core/JNILib";
constexpr const char* kGtasaClass = "com.arizona.game.GTASA";

// Android объявляет AttachCurrentThread(JNIEnv**), а JDK — (void**).
// Шаблон выводит тип прямо из объявления в подключённом jni.h, поэтому
// исходник собирается и NDK, и hostcheck'ом на заголовках JDK.
template <typename EnvPtrPtr>
jint attach_current_thread(JavaVM* vm, jint (JavaVM::*fn)(EnvPtrPtr, void*),
                           JNIEnv** env)
{
  return (vm->*fn)(reinterpret_cast<EnvPtrPtr>(env), nullptr);
}

JavaVM* g_vm = nullptr;
jclass g_jnilib_class = nullptr;

// Класс GTASA берётся не через FindClass, а через classLoader.loadClass():
// FindClass из фонового потока видит только системный загрузчик классов,
// а вызывать его прямо в JNI_OnLoad нельзя — это инициализировало бы GTASA
// посреди <clinit> другого класса.
jobject g_class_loader = nullptr;
jmethodID g_load_class = nullptr;
jclass g_gtasa_class = nullptr;

// Объект активити берём из статического поля GTASA._instance — оно есть с
// самого старта. Раньше его ловили из первого OnInputEnd, то есть до первой
// отправки чего-либо в чат ни клавиатуру открыть, ни текст послать было
// нечем.
jobject g_gtasa_instance = nullptr;
jmethodID g_t_on_input_end = nullptr;

// GTASA.SetInputLayout(int type, boolean is_chat) — то самое, чем игра
// открывает клавиатуру под чат. Ненулевой тип открывает, ноль закрывает,
// а runOnUiThread метод делает сам, поэтому звать можно откуда угодно.
jmethodID g_set_input_layout = nullptr;

// Клавиатуру открыли мы, а не игра: значит следующий OnInputEnd — ответ
// нашему полю ввода, и в игру его пускать нельзя, иначе текст уйдёт в чат.
std::atomic<bool> g_keyboard_ours { false };

// t_OnInputEnd перекладывает вызов на UI-поток, поэтому к моменту, когда
// сработает наш хук, «флаг отправки» уже сбросился бы. Вместо флага держим
// список того, что отправили сами, и не разбираем эти строки как команды —
// иначе скрипт, отправивший '/что-то', зациклил бы сам себя.
std::mutex g_sent_lock;
std::deque<std::string> g_sent_lines;

bool take_own_line(const std::string& line)
{
  std::lock_guard<std::mutex> guard { g_sent_lock };
  for (auto it = g_sent_lines.begin(); it != g_sent_lines.end(); ++it) {
    if (*it == line) {
      g_sent_lines.erase(it);
      return true;
    }
  }
  return false;
}

std::atomic<bool> g_ready { false };
std::atomic<int> g_width { 0 };
std::atomic<int> g_height { 0 };
std::atomic<long long> g_frames { 0 };
std::atomic<double> g_frame_time { 0.0 };

std::chrono::steady_clock::time_point g_last_frame;
bool g_have_last_frame = false;
bool g_gui_started = false;
bool g_gui_failed = false;

// ---------------------------------------------------------------- обёртки

void JNICALL hk_android_init(JNIEnv* env, jclass cls, jstring settings)
{
  AG_LOGI("androidInit — движок инициализируется");
  engine::anchors().android_init(env, cls, settings);

  // Скрипты стартуют после инициализации движка, но до первого кадра.
  script::manager::start();
}

void JNICALL hk_android_step(JNIEnv* env, jclass cls)
{
  engine::anchors().android_step(env, cls);

  // androidInit у уже проинициализированной игры проходит раньше, чем мы
  // успеваем перехватить якоря, и тогда его хук не срабатывает никогда.
  // Кадр же случается гарантированно, поэтому подстраховываемся здесь —
  // start() идемпотентен и второй раз ничего не делает.
  script::manager::start();

  const auto now = std::chrono::steady_clock::now();
  double dt = 1.0 / 60.0;
  if (g_have_last_frame) {
    dt = std::chrono::duration<double>(now - g_last_frame).count();
    if (dt <= 0.0 || dt > 1.0) {
      dt = 1.0 / 60.0;
    }
  }
  g_last_frame = now;
  g_have_last_frame = true;
  g_frame_time.store(dt);
  g_frames.fetch_add(1);

  if (!g_gui_started && !g_gui_failed) {
    // Контекст GL уже текущий — самое время поднять ImGui.
    g_gui_started = gui::init();
    if (!g_gui_started) {
      // Одной попытки достаточно: если ImGui не поднялся, он не поднимется
      // и на следующем кадре, а спамить в лог каждый кадр незачем.
      g_gui_failed = true;
      AG_LOGE("интерфейс не поднялся, скрипты продолжат работать без него");
    }
  }

  // Скрипты крутятся независимо от интерфейса.
  script::manager::on_frame(dt);
  if (g_gui_started) {
    gui::render(dt);
  }
}

void JNICALL hk_android_resize(JNIEnv* env, jclass cls, jint w, jint h)
{
  AG_LOGI("androidResize %dx%d", static_cast<int>(w), static_cast<int>(h));
  g_width.store(w);
  g_height.store(h);
  gui::on_resize(w, h);
  engine::anchors().android_resize(env, cls, w, h);
}

void JNICALL hk_android_multi_touch(JNIEnv* env, jclass cls, jint action,
                                    jint pointer_id, jint x, jint y, jint x1,
                                    jint y1, jint x2, jint y2)
{
  const bool consumed =
      input::on_touch(action, pointer_id, x, y, x1, y1, x2, y2);
  if (consumed) {
    return;  // палец «съеден» меню — игра события не увидит
  }
  engine::anchors().android_multi_touch(env, cls, action, pointer_id, x, y, x1, y1,
                                        x2, y2);
}

void JNICALL hk_android_key_event(JNIEnv* env, jclass cls, jint code, jint action)
{
  if (script::manager::on_key(code, action)) {
    return;
  }
  engine::anchors().android_key_event(env, cls, code, action);
}

void JNICALL hk_android_pause(JNIEnv* env, jclass cls)
{
  // Пальцы, поднятые уже после сворачивания, до нас не дойдут — сбрасываем
  // захват сами, иначе меню останется «зажатым».
  input::reset();
  script::manager::on_pause();
  engine::anchors().android_pause(env, cls);
}

void JNICALL hk_android_resume(JNIEnv* env, jclass cls)
{
  gui::on_context_maybe_lost();
  script::manager::on_resume();
  engine::anchors().android_resume(env, cls);
}

std::string jstring_to_utf8(JNIEnv* env, jstring js)
{
  if (js == nullptr) {
    return {};
  }
  const char* raw = env->GetStringUTFChars(js, nullptr);
  if (raw == nullptr) {
    return {};
  }
  std::string out { raw };
  env->ReleaseStringUTFChars(js, raw);
  return out;
}

void JNICALL hk_on_input_end(JNIEnv* env, jobject thiz, jstring text)
{
  if (g_gtasa_instance == nullptr && thiz != nullptr) {
    g_gtasa_instance = env->NewGlobalRef(thiz);
  }

  const std::string line = jstring_to_utf8(env, text);

  // Клавиатуру открывали под наше поле ввода — текст забираем себе целиком
  // и в игру не отдаём, иначе он ушёл бы в чат.
  if (g_keyboard_ours.exchange(false)) {
    gui::deliver_text(line);
    return;
  }

  if (!line.empty() && !take_own_line(line) &&
      script::manager::on_chat_input(line)) {
    return;  // команда обработана скриптом, игре её не передаём
  }

  engine::anchors().on_input_end(env, thiz, text);
}

// Клавиатуру закрыли, ничего не отправив. Если её открывали мы, поле ввода
// должно об этом узнать, иначе оно так и осталось бы ждать.
void JNICALL hk_on_keyboard_closed(JNIEnv* env, jobject thiz)
{
  if (g_keyboard_ours.exchange(false)) {
    gui::cancel_text();
  }
  engine::anchors().on_keyboard_closed(env, thiz);
}

const JNINativeMethod kMethods[] = {
    { const_cast<char*>("androidInit"), const_cast<char*>("(Ljava/lang/String;)V"),
      reinterpret_cast<void*>(hk_android_init) },
    { const_cast<char*>("androidStep"), const_cast<char*>("()V"),
      reinterpret_cast<void*>(hk_android_step) },
    { const_cast<char*>("androidResize"), const_cast<char*>("(II)V"),
      reinterpret_cast<void*>(hk_android_resize) },
    { const_cast<char*>("androidMultiTouch"), const_cast<char*>("(IIIIIIII)V"),
      reinterpret_cast<void*>(hk_android_multi_touch) },
    { const_cast<char*>("androidKeyEvent"), const_cast<char*>("(II)V"),
      reinterpret_cast<void*>(hk_android_key_event) },
    { const_cast<char*>("androidPause"), const_cast<char*>("()V"),
      reinterpret_cast<void*>(hk_android_pause) },
    { const_cast<char*>("androidResume"), const_cast<char*>("()V"),
      reinterpret_cast<void*>(hk_android_resume) },
};

const JNINativeMethod kGtasaMethods[] = {
    { const_cast<char*>("OnInputEnd"), const_cast<char*>("(Ljava/lang/String;)V"),
      reinterpret_cast<void*>(hk_on_input_end) },
    { const_cast<char*>("OnKeyboardClosed"), const_cast<char*>("()V"),
      reinterpret_cast<void*>(hk_on_keyboard_closed) },
};

// ------------------------------------------------------------ инициализация

void init_thread()
{
  if (!engine::wait_and_resolve(30000)) {
    AG_LOGE("движок не найден — загрузчик остаётся выключенным");
    return;
  }

  JNIEnv* env = nullptr;
  const jint attach =
      attach_current_thread(g_vm, &JavaVM::AttachCurrentThread, &env);
  if (attach != JNI_OK || env == nullptr) {
    AG_LOGE("AttachCurrentThread не удался (%d)", static_cast<int>(attach));
    return;
  }

  // Скрипты загружаем до перерегистрации: иначе первый же androidStep
  // придёт в пустой менеджер.
  script::manager::init();

  const jint rc = env->RegisterNatives(
      g_jnilib_class, kMethods,
      static_cast<jint>(sizeof(kMethods) / sizeof(kMethods[0])));
  if (rc != JNI_OK) {
    if (env->ExceptionCheck()) {
      env->ExceptionDescribe();
      env->ExceptionClear();
    }
    AG_LOGE("RegisterNatives не удался (%d)", static_cast<int>(rc));
    g_vm->DetachCurrentThread();
    return;
  }

  // Чат — отдельным классом и отдельной регистрацией: если он почему-то
  // не найдётся, всё остальное должно продолжать работать.
  if (g_class_loader != nullptr && g_load_class != nullptr) {
    jstring name = env->NewStringUTF(kGtasaClass);
    jobject cls = env->CallObjectMethod(g_class_loader, g_load_class, name);
    env->DeleteLocalRef(name);

    if (env->ExceptionCheck()) {
      env->ExceptionClear();
      cls = nullptr;
    }
    if (cls != nullptr) {
      g_gtasa_class = static_cast<jclass>(env->NewGlobalRef(cls));
      env->DeleteLocalRef(cls);

      const jint rc_chat = env->RegisterNatives(
          g_gtasa_class, kGtasaMethods,
          static_cast<jint>(sizeof(kGtasaMethods) / sizeof(kGtasaMethods[0])));
      if (rc_chat == JNI_OK) {
        g_t_on_input_end = env->GetMethodID(g_gtasa_class, "t_OnInputEnd",
                                            "(Ljava/lang/String;)V");
        if (env->ExceptionCheck()) {
          env->ExceptionClear();
          g_t_on_input_end = nullptr;
        }

        // Клавиатура: метод, которым игра открывает поле чата, и активити
        // из статического поля — без него звать метод не на чем.
        g_set_input_layout =
            env->GetMethodID(g_gtasa_class, "SetInputLayout", "(IZ)V");
        if (env->ExceptionCheck()) {
          env->ExceptionClear();
          g_set_input_layout = nullptr;
        }

        if (g_gtasa_instance == nullptr) {
          const jfieldID inst = env->GetStaticFieldID(
              g_gtasa_class, "_instance", "Lcom/arizona/game/GTASA;");
          if (env->ExceptionCheck()) {
            env->ExceptionClear();
          } else if (inst != nullptr) {
            jobject obj = env->GetStaticObjectField(g_gtasa_class, inst);
            if (obj != nullptr) {
              g_gtasa_instance = env->NewGlobalRef(obj);
              env->DeleteLocalRef(obj);
            }
          }
        }

        AG_LOGI("чат перехвачен, команды доступны%s",
                (g_set_input_layout != nullptr && g_gtasa_instance != nullptr)
                    ? ", клавиатура игры доступна"
                    : ", клавиатура игры недоступна");
      } else {
        if (env->ExceptionCheck()) {
          env->ExceptionClear();
        }
        AG_LOGW("не удалось перехватить чат (%d) — команды работать не будут",
                static_cast<int>(rc_chat));
      }
    } else {
      AG_LOGW("класс %s не найден — команды работать не будут", kGtasaClass);
    }
  }

  g_vm->DetachCurrentThread();

  g_ready.store(true);
  AG_LOGI("якоря перехвачены, загрузчик готов");
}

}  // namespace

bool ready() { return g_ready.load(); }

Screen screen()
{
  Screen s;
  s.width = g_width.load();
  s.height = g_height.load();
  return s;
}

double frame_time() { return g_frame_time.load(); }
long long frame_count() { return g_frames.load(); }
JavaVM* vm() { return g_vm; }

bool keyboard_available()
{
  return g_set_input_layout != nullptr && g_gtasa_instance != nullptr;
}

// Открывает клавиатуру игры — ту же, что и под чатом, со всеми её
// настройками и раскладками. Текст придёт в OnInputEnd, который мы уже
// перехватываем; флаг говорит, что это ответ нам, а не сообщение в чат.
bool show_keyboard()
{
  if (!keyboard_available() || g_vm == nullptr) {
    return false;
  }
  JNIEnv* env = nullptr;
  if (g_vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
    return false;
  }
  g_keyboard_ours.store(true);
  // Первый аргумент — тип поля, второй — «это чат». Чатом не притворяемся:
  // тогда игра не подставит свою историю сообщений и подсказки команд.
  env->CallVoidMethod(g_gtasa_instance, g_set_input_layout,
                      static_cast<jint>(1), JNI_FALSE);
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
    g_keyboard_ours.store(false);
    return false;
  }
  return true;
}

void hide_keyboard()
{
  if (!keyboard_available() || g_vm == nullptr) {
    return;
  }
  JNIEnv* env = nullptr;
  if (g_vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
    return;
  }
  g_keyboard_ours.store(false);
  env->CallVoidMethod(g_gtasa_instance, g_set_input_layout,
                      static_cast<jint>(0), JNI_FALSE);
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
  }
}

bool inject_touch(int action, int pointer_id, int x, int y)
{
  auto fn = engine::anchors().android_multi_touch;
  if (fn == nullptr || g_jnilib_class == nullptr || g_vm == nullptr) {
    return false;
  }

  JNIEnv* env = nullptr;
  if (g_vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
    return false;  // не с потока отрисовки — событие ушло бы не туда
  }

  // Движок ждёт координаты и самого пальца, и обоих отслеживаемых сразу.
  // Для одного пальца остальные слоты просто повторяют его же.
  const jint jx = static_cast<jint>(x);
  const jint jy = static_cast<jint>(y);
  jint x1 = jx;
  jint y1 = jy;
  jint x2 = 0;
  jint y2 = 0;
  if (pointer_id != 0) {
    x1 = 0;
    y1 = 0;
    x2 = jx;
    y2 = jy;
  }

  fn(env, g_jnilib_class, static_cast<jint>(action),
     static_cast<jint>(pointer_id), jx, jy, x1, y1, x2, y2);
  return true;
}

void set_screen(int width, int height)
{
  if (width > 0 && height > 0) {
    g_width.store(width);
    g_height.store(height);
  }
}

bool can_send_chat()
{
  return g_gtasa_instance != nullptr && g_t_on_input_end != nullptr;
}

bool send_chat(const std::string& text)
{
  if (!can_send_chat() || text.empty()) {
    return false;
  }

  JNIEnv* env = nullptr;
  bool attached = false;
  if (g_vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
    if (attach_current_thread(g_vm, &JavaVM::AttachCurrentThread, &env) != JNI_OK) {
      return false;
    }
    attached = true;
  }

  {
    std::lock_guard<std::mutex> guard { g_sent_lock };
    g_sent_lines.push_back(text);
    // Страховка от рассинхрона: если хук по какой-то причине не сработает,
    // список не должен расти бесконечно.
    while (g_sent_lines.size() > 16) {
      g_sent_lines.pop_front();
    }
  }

  jstring js = env->NewStringUTF(text.c_str());
  // t_OnInputEnd публичный и сам перекладывает вызов на UI-поток, поэтому
  // звать его можно откуда угодно — в отличие от нативного OnInputEnd.
  env->CallVoidMethod(g_gtasa_instance, g_t_on_input_end, js);

  if (env->ExceptionCheck()) {
    env->ExceptionClear();
  }
  env->DeleteLocalRef(js);

  if (attached) {
    g_vm->DetachCurrentThread();
  }
  return true;
}

}  // namespace ag::loader

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* /*reserved*/)
{
  using namespace ag;

  loader::g_vm = vm;

  JNIEnv* env = nullptr;
  if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
    return JNI_VERSION_1_6;
  }

  paths::init();
  log::init(paths::logs());
  AG_LOGI("AGLoader " AGLOADER_VERSION " — загрузчик Lua для нового движка Arizona");
  AG_LOGI("пакет: %s", paths::package().c_str());
  AG_LOGI("данные: %s", paths::root().c_str());

  // JNI_OnLoad вызывается из <clinit> JNILib, то есть classloader приложения
  // уже в контексте текущего потока — FindClass здесь отработает, а из
  // фонового потока уже нет. Поэтому запоминаем класс сразу.
  jclass local = env->FindClass(loader::kJniLibClass);
  if (local == nullptr) {
    if (env->ExceptionCheck()) {
      env->ExceptionDescribe();
      env->ExceptionClear();
    }
    AG_LOGE("класс %s не найден — загрузчик выключен", loader::kJniLibClass);
    return JNI_VERSION_1_6;
  }
  loader::g_jnilib_class = static_cast<jclass>(env->NewGlobalRef(local));

  // Тот же приём для GTASA не годится: FindClass инициализировал бы класс
  // прямо посреди <clinit> JNILib. Поэтому запоминаем загрузчик классов
  // приложения и достанем GTASA через него позже, из фонового потока.
  jclass class_class = env->FindClass("java/lang/Class");
  if (class_class != nullptr) {
    jmethodID get_loader = env->GetMethodID(class_class, "getClassLoader",
                                            "()Ljava/lang/ClassLoader;");
    if (get_loader != nullptr) {
      jobject cl = env->CallObjectMethod(local, get_loader);
      if (cl != nullptr) {
        loader::g_class_loader = env->NewGlobalRef(cl);
        jclass cl_class = env->GetObjectClass(cl);
        loader::g_load_class = env->GetMethodID(
            cl_class, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
        env->DeleteLocalRef(cl_class);
        env->DeleteLocalRef(cl);
      }
    }
    env->DeleteLocalRef(class_class);
  }
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
  }
  if (loader::g_class_loader == nullptr) {
    AG_LOGW("загрузчик классов не получен — чат-команды будут недоступны");
  }

  env->DeleteLocalRef(local);

  // Движок в этот момент ещё не загружен (наш loadLibrary идёт первым),
  // поэтому резолв и перерегистрация — в фоне.
  std::thread { loader::init_thread }.detach();
  return JNI_VERSION_1_6;
}
