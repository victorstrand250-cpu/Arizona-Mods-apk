cmake_minimum_required(VERSION 3.22)
project(agloader LANGUAGES C CXX)

set(AGLOADER_VERSION "0.1.0" CACHE STRING "Версия загрузчика")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT ANDROID)
  message(FATAL_ERROR
    "agloader собирается только Android NDK.\n"
    "Пример:\n"
    "  cmake -B build -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \\\n"
    "        -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24\n"
    "Либо запустите ./build.sh")
endif()

# ------------------------------------------------------------------ imgui

add_library(imgui STATIC
  third_party/imgui/imgui.cpp
  third_party/imgui/imgui_draw.cpp
  third_party/imgui/imgui_tables.cpp
  third_party/imgui/imgui_widgets.cpp
  third_party/imgui/backends/imgui_impl_opengl3.cpp
)
# У движка своя копия ImGui. Наши символы не должны быть видны снаружи,
# иначе его вызовы уедут к нам — см. exports.map.
target_compile_options(imgui PRIVATE -fvisibility=hidden -fvisibility-inlines-hidden)
target_include_directories(imgui PUBLIC
  third_party/imgui
  third_party/imgui/backends
)
# Бэкенд ImGui сам определяет GLES по этому макросу.
target_compile_definitions(imgui PUBLIC
  IMGUI_IMPL_OPENGL_ES3
  IMGUI_DISABLE_OBSOLETE_FUNCTIONS
  IMGUI_DISABLE_DEMO_WINDOWS
)
target_link_libraries(imgui PUBLIC GLESv3 EGL)

# ----------------------------------------------------------------- luajit

set(LUAJIT_LIB "${CMAKE_CURRENT_SOURCE_DIR}/third_party/luajit/lib/${ANDROID_ABI}/libluajit-5.1.so")
if(NOT EXISTS "${LUAJIT_LIB}")
  message(FATAL_ERROR "нет готового LuaJIT для ABI ${ANDROID_ABI}: ${LUAJIT_LIB}")
endif()

add_library(luajit SHARED IMPORTED)
set_target_properties(luajit PROPERTIES IMPORTED_LOCATION "${LUAJIT_LIB}")
target_include_directories(luajit INTERFACE third_party/luajit/include)

# --------------------------------------------------------------- загрузчик

add_library(agloader SHARED
  src/loader.cpp
  src/engine.cpp
  src/gui.cpp
  src/input.cpp
  src/log.cpp
  src/paths.cpp
  src/net.cpp
  src/script/manager.cpp
  src/script/script.cpp
  src/script/prelude.cpp
  src/script/api_core.cpp
  src/script/api_memory.cpp
  src/script/api_net.cpp
  src/script/api_imgui.cpp
)

target_include_directories(agloader PRIVATE src)
target_compile_definitions(agloader PRIVATE AGLOADER_VERSION="${AGLOADER_VERSION}")
target_compile_options(agloader PRIVATE
  -Wall -Wextra -Wno-unused-parameter -fvisibility=hidden
)
target_link_libraries(agloader PRIVATE imgui luajit log android EGL GLESv3)

# Наружу отдаём только JNI_OnLoad, всё остальное прячем — см. exports.map.
# Одного -fvisibility=hidden мало: он стоит PRIVATE у agloader и на статическую
# библиотеку imgui не распространяется, поэтому её символы утекали в
# динамическую таблицу и перехватывали вызовы ImGui у самого движка.
target_link_options(agloader PRIVATE
  -Wl,--no-undefined
  -Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/exports.map
  -Wl,--exclude-libs,ALL
)

if(CMAKE_BUILD_TYPE STREQUAL "Release")
  target_compile_options(agloader PRIVATE -O2)
endif()
