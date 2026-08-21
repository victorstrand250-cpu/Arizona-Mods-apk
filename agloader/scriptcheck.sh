#!/usr/bin/env bash
# Проверка Lua-части без телефона и без игры.
#
# Сначала синтаксис всех скриптов и библиотек, потом настоящий прогон на
# lua5.1: каждый скрипт грузится, рисует кадр и отвечает на свои чат-команды
# с заглушками вместо загрузчика. Так ловятся опечатки в именах imgui и
# обращения к памяти без проверки на nil — то, что иначе видно только в игре.
set -euo pipefail
cd "$(dirname "$0")"

LUA=$(command -v lua5.1 || command -v luajit || true)
LUAC=$(command -v luac5.1 || true)
if [ -z "$LUA" ]; then
  echo "scriptcheck: нужен lua5.1 или luajit (apt install lua5.1)" >&2
  exit 1
fi

echo "scriptcheck: синтаксис"
fail=0
if [ -n "$LUAC" ]; then
  while IFS= read -r f; do
    # sha1 выбирает набор битовых операций по версии Lua; вариант для 5.3
    # написан на её синтаксисе и под 5.1 не разбирается — он и не грузится.
    case "$f" in lib/sha1/lua53_ops.lua) continue ;; esac
    if ! out=$("$LUAC" -p "$f" 2>&1); then
      echo "  $f"
      echo "    $out"
      fail=1
    fi
  done < <(find scripts lib -name '*.lua' | sort)
else
  echo "  luac5.1 не найден, проверка синтаксиса пропущена"
fi
[ "$fail" = 0 ] || exit 1
echo "  все файлы разбираются"

# Пролог загрузчика живёт строкой внутри prelude.cpp — вынимаем как есть,
# чтобы проверять ровно то, что попадёт в игру.
prelude=$(mktemp /tmp/agl-prelude-XXXXXX.lua)
trap 'rm -f "$prelude"' EXIT
python3 - "$prelude" <<'PY'
import re, sys
src = open('src/script/prelude.cpp').read()
m = re.search(r'R"LUA\((.*)\)LUA"', src, re.S)
if not m:
    sys.exit('не нашёл текст пролога в prelude.cpp')
open(sys.argv[1], 'w').write(m.group(1))
PY

if [ -n "$LUAC" ] && ! "$LUAC" -p "$prelude" >/dev/null 2>&1; then
  echo "scriptcheck: пролог в prelude.cpp не разбирается" >&2
  "$LUAC" -p "$prelude" || true
  exit 1
fi

echo "scriptcheck: проверка lib/arizona"
AGL_ROOT=. "$LUA" test/arizona_spec.lua

echo "scriptcheck: прогон скриптов"
AGL_ROOT=. AGL_TEST=test AGL_CFG=$(mktemp -d) \
  "$LUA" test/runscripts.lua "$prelude"
echo "scriptcheck: все скрипты живут"
