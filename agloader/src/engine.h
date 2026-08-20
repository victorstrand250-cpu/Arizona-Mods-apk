// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <jni.h>

#include <cstdint>
#include <string>
#include <vector>

namespace ag::engine {

// Единственные точки, которые новый движок Arizona экспортирует наружу.
// Всё остальное в libag-client.so вырезано strip'ом, поэтому загрузчик
// строится вокруг этих семи функций.
struct Anchors {
  void (*android_init)(JNIEnv*, jclass, jstring) = nullptr;
  void (*android_step)(JNIEnv*, jclass) = nullptr;
  void (*android_resize)(JNIEnv*, jclass, jint, jint) = nullptr;
  void (*android_multi_touch)(JNIEnv*, jclass, jint, jint, jint, jint, jint, jint,
                              jint, jint) = nullptr;
  void (*android_key_event)(JNIEnv*, jclass, jint, jint) = nullptr;
  void (*android_pause)(JNIEnv*, jclass) = nullptr;
  void (*android_resume)(JNIEnv*, jclass) = nullptr;
};

// Блокирующе ждёт появления libag-client.so в процессе (dlopen NOLOAD),
// затем резолвит якоря. timeout_ms < 0 — ждать бесконечно.
bool wait_and_resolve(int timeout_ms);

bool resolved();
const Anchors& anchors();

// Диапазон загруженного модуля по /proc/self/maps.
struct Module {
  std::string path;
  std::uintptr_t base = 0;
  std::uintptr_t end = 0;
};
bool find_module(const std::string& name_suffix, Module* out);
std::vector<Module> modules();

// База и размер самого движка (0, если ещё не загружен).
std::uintptr_t client_base();
std::size_t client_size();

}  // namespace ag::engine
