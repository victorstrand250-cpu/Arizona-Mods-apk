#!/usr/bin/env bash
# Проверка компиляции без Android NDK.
#
# Настоящую библиотеку собирает build.sh / CI под NDK. Этот скрипт нужен,
# чтобы поймать ошибки компиляции локально: берём кросс-компилятор
# aarch64-linux-gnu-g++, заголовки JNI от JDK, GLES/EGL от Khronos и
# крошечную заглушку android/log.h. ABI bionic от glibc отличается, поэтому
# результат годится только как проверка синтаксиса и кодогенерации ARM64 —
# запускать его на устройстве нельзя.
#
#   sudo apt-get install -y g++-aarch64-linux-gnu libgles-dev libegl-dev
#   ./hostcheck.sh
set -euo pipefail

cd "$(dirname "$0")"

CXX=${CXX:-aarch64-linux-gnu-g++}
READELF=${READELF:-aarch64-linux-gnu-readelf}
JAVA_INC=${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}/include
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

mkdir -p "$OUT/shim/android"
cat > "$OUT/shim/android/log.h" <<'EOF'
// Заглушка android/log.h только для hostcheck.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
enum {
  ANDROID_LOG_UNKNOWN = 0, ANDROID_LOG_DEFAULT, ANDROID_LOG_VERBOSE,
  ANDROID_LOG_DEBUG, ANDROID_LOG_INFO, ANDROID_LOG_WARN, ANDROID_LOG_ERROR,
  ANDROID_LOG_FATAL, ANDROID_LOG_SILENT
};
int __android_log_write(int prio, const char* tag, const char* text);
int __android_log_print(int prio, const char* tag, const char* fmt, ...);
#ifdef __cplusplus
}
#endif
EOF

SOURCES=(
  src/loader.cpp
  src/engine.cpp
  src/gui.cpp
  src/input.cpp
  src/log.cpp
  src/paths.cpp
  src/script/manager.cpp
  src/script/script.cpp
  src/script/api_core.cpp
  src/script/api_memory.cpp
  src/script/api_imgui.cpp
)

IMGUI_SOURCES=(
  third_party/imgui/imgui.cpp
  third_party/imgui/imgui_draw.cpp
  third_party/imgui/imgui_tables.cpp
  third_party/imgui/imgui_widgets.cpp
  third_party/imgui/backends/imgui_impl_opengl3.cpp
)

FLAGS=(
  -std=c++17 -c -O1 -Wall -Wextra -Wno-unused-parameter
  -D__ANDROID__=1
  -DAGLOADER_VERSION='"hostcheck"'
  -DIMGUI_IMPL_OPENGL_ES3
  -DIMGUI_DISABLE_OBSOLETE_FUNCTIONS
  -DIMGUI_DISABLE_DEMO_WINDOWS
  -I src
  -I third_party/imgui
  -I third_party/imgui/backends
  -I third_party/luajit/include
  -I "$JAVA_INC"
  -I "$JAVA_INC/linux"
  -I "$OUT/shim"
)

fail=0
for f in "${IMGUI_SOURCES[@]}" "${SOURCES[@]}"; do
  printf '  %-52s ' "$f"
  if "$CXX" "${FLAGS[@]}" "$f" -o "$OUT/$(basename "$f").o" 2> "$OUT/err.txt"; then
    echo "ok"
  else
    echo "ОШИБКА"
    sed 's/^/      /' "$OUT/err.txt"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "hostcheck: есть ошибки компиляции"
  exit 1
fi
echo "hostcheck: все файлы компилируются"

# Отдельно проверяем exports.map: собрать всю библиотеку здесь нельзя (нужны
# библиотеки Android), но синтаксис скрипта версий и то, что он не называет
# несуществующих символов, проверяется пустышкой. Флаги те же, что у NDK:
# --no-undefined-version превращает лишнее имя в ошибку линковки.
printf '  %-52s ' "exports.map"
cat > "$OUT/vs.cpp" <<'EOF'
extern "C" __attribute__((visibility("default"))) int JNI_OnLoad(void*, void*)
{
  return 0x00010006;
}
extern "C" int should_stay_hidden() { return 1; }
EOF

if ! "$CXX" -shared -fPIC "$OUT/vs.cpp" -o "$OUT/vs.so" \
     -Wl,--version-script="$(dirname "$0")/exports.map" \
     -Wl,--exclude-libs,ALL -Wl,--no-undefined-version -Wl,--fatal-warnings \
     2> "$OUT/err.txt"; then
  echo "ОШИБКА"
  sed 's/^/      /' "$OUT/err.txt"
  exit 1
fi

exported=$("$READELF" --dyn-syms "$OUT/vs.so" \
  | awk '$5 == "GLOBAL" || $5 == "WEAK" { if ($7 != "UND") print $8 }' \
  | sed 's/@.*//' | grep -v '^$' | sort -u)
if [ "$exported" != "JNI_OnLoad" ]; then
  echo "ОШИБКА"
  echo "      наружу должен торчать только JNI_OnLoad, а торчит:"
  echo "$exported" | sed 's/^/        /'
  exit 1
fi
echo "ok (наружу только JNI_OnLoad)"
