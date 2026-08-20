#!/usr/bin/env bash
# Сборка libagloader.so под Android.
#
# Нужен Android NDK r25+ — путь берётся из ANDROID_NDK_HOME,
# ANDROID_NDK_LATEST_HOME, ANDROID_NDK_ROOT или из --ndk.
#
#   ./build.sh                      # обе ABI, Release
#   ./build.sh --abi arm64-v8a      # только arm64
#   ./build.sh --debug
#
# Результат: dist/<abi>/libagloader.so и dist/<abi>/libluajit-5.1.so
set -euo pipefail

cd "$(dirname "$0")"

ABIS="arm64-v8a armeabi-v7a"
BUILD_TYPE=Release
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-${ANDROID_NDK_ROOT:-}}}"
API=24

while [ $# -gt 0 ]; do
  case "$1" in
    --abi) ABIS="$2"; shift 2 ;;
    --ndk) NDK="$2"; shift 2 ;;
    --api) API="$2"; shift 2 ;;
    --debug) BUILD_TYPE=Debug; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$NDK" ] || [ ! -d "$NDK" ]; then
  cat >&2 <<'EOF'
Не найден Android NDK.

Укажите путь явно:
    ./build.sh --ndk /path/to/android-ndk-r27c
или задайте ANDROID_NDK_HOME.

NDK ставится через Android Studio (SDK Manager -> NDK) либо
sdkmanager --install "ndk;27.2.12479018".

Если собирать локально негде — используйте GitHub Actions:
workflow .github/workflows/agloader.yml собирает обе ABI и
выкладывает готовые .so артефактом.
EOF
  exit 1
fi

TOOLCHAIN="$NDK/build/cmake/android.toolchain.cmake"
if [ ! -f "$TOOLCHAIN" ]; then
  echo "нет $TOOLCHAIN — путь к NDK указан неверно" >&2
  exit 1
fi

rm -rf dist
for abi in $ABIS; do
  echo "=== $abi ($BUILD_TYPE)"
  cmake -S . -B "build/$abi" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DANDROID_ABI="$abi" \
    -DANDROID_PLATFORM="android-$API" \
    -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_MAKE_PROGRAM="$(command -v ninja || command -v make)" \
    -G "$(command -v ninja >/dev/null && echo Ninja || echo 'Unix Makefiles')"
  cmake --build "build/$abi" --parallel

  mkdir -p "dist/$abi"
  cp "build/$abi/libagloader.so" "dist/$abi/"
  cp "third_party/luajit/lib/$abi/libluajit-5.1.so" "dist/$abi/"

  if [ "$BUILD_TYPE" = "Release" ]; then
    STRIP="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
    [ -x "$STRIP" ] && "$STRIP" --strip-unneeded "dist/$abi/libagloader.so" || true
  fi
done

echo
echo "готово:"
find dist -type f -name '*.so' -exec ls -la {} \;
echo
echo "Дальше — встроить в APK:"
echo "  python3 ../tools/inject_native_lib.py \\"
echo "      --apk ARIZONA.ONLINE.apk --out ARIZONA.ONLINE_agloader.apk \\"
echo "      --load luajit-5.1 --load agloader \\"
echo "      --lib arm64-v8a=dist/arm64-v8a/libluajit-5.1.so \\"
echo "      --lib arm64-v8a=dist/arm64-v8a/libagloader.so \\"
echo "      --smali smali.jar --baksmali baksmali.jar"
