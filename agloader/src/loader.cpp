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

JavaVM* g_vm = nullptr;
jclass g_jnilib_class = nullptr;

std::atomic<bool> g_ready { false };
std::atomic<int> g_width { 0 };
std::atomic<int> g_height { 0 };
std::atomic<long long> g_frames { 0 };
std::atomic<double> g_frame_time { 0.0 };

std::chrono::steady_clock::time_point g_last_frame;
bool g_have_last_frame = false;
bool g_gui_started = false;

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

  if (!g_gui_started) {
    // Контекст GL уже текущий — самое время поднять ImGui.
    g_gui_started = gui::init();
    if (!g_gui_started) {
      return;
    }
  }

  script::manager::on_frame(dt);
  gui::render(dt);
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
  script::manager::on_pause();
  engine::anchors().android_pause(env, cls);
}

void JNICALL hk_android_resume(JNIEnv* env, jclass cls)
{
  script::manager::on_resume();
  engine::anchors().android_resume(env, cls);
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

// ------------------------------------------------------------ инициализация

void init_thread()
{
  if (!engine::wait_and_resolve(30000)) {
    AG_LOGE("движок не найден — загрузчик остаётся выключенным");
    return;
  }

  JNIEnv* env = nullptr;
  // Android объявляет AttachCurrentThread(JNIEnv**), JDK — (void**);
  // приведение делает исходник переносимым между обоими заголовками.
  const jint attach =
      g_vm->AttachCurrentThread(reinterpret_cast<void**>(&env), nullptr);
  if (attach != JNI_OK || env == nullptr) {
    AG_LOGE("AttachCurrentThread не удался (%d)", static_cast<int>(attach));
    return;
  }

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
  g_vm->DetachCurrentThread();

  script::manager::init();
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
  env->DeleteLocalRef(local);

  // Движок в этот момент ещё не загружен (наш loadLibrary идёт первым),
  // поэтому резолв и перерегистрация — в фоне.
  std::thread { loader::init_thread }.detach();
  return JNI_VERSION_1_6;
}
