# AGLoader

Lua-загрузчик для **нового** движка Arizona Mobile (`libag-client.so`).

MonetLoader на новом движке не работает и работать не может: он резолвит
функции игры по именам в `libGTASA.so`, а новый клиент собран stripped —
из 46 нужных символов нет ни одного (разбор: [`../docs/MONETLOADER_NEW_ENGINE.md`](../docs/MONETLOADER_NEW_ENGINE.md)).
AGLoader — не порт MonetLoader, а отдельный загрузчик, построенный на том,
что новый движок **всё-таки** отдаёт наружу.

## Готовый APK

Собирать ничего не обязательно. Каждая сборка в GitHub Actions выкладывает
два артефакта:

* **`arizona-agloader-apk`** — `ARIZONA.ONLINE_v17.7.1_agloader.apk`,
  уже с встроенным загрузчиком и подписанный отладочным ключом. Скачать,
  распаковать zip, поставить.
* **`agloader-libs`** — только `.so` под обе ABI, если хотите встроить их
  в свой APK самостоятельно.

Actions → agloader → последний зелёный запуск → раздел Artifacts.

> Подпись отладочная, поэтому поверх официальной игры APK не встанет —
> сначала удалите оригинал (или соберите со своим ключом).

## На чём он держится

`libag-client.so` экспортирует ровно семь функций — JNI-методы класса
`com.arizonagames.client.game.core.JNILib`:

| функция | что даёт загрузчику |
|---|---|
| `androidStep()` | тик кадра на GL-потоке, **после** отрисовки игры и **до** `eglSwapBuffers` — идеальная точка для оверлея |
| `androidMultiTouch(action, id, x, y, x1, y1, x2, y2)` | тач-ввод; можно поглощать, не пропуская в игру |
| `androidResize(w, h)` | размеры экрана |
| `androidInit(json)` | момент инициализации движка |
| `androidKeyEvent(code, action)` | клавиши |
| `androidPause()` / `androidResume()` | сворачивание |

Перехват сделан **не инлайн-хуком**, а через `RegisterNatives`:

1. `libagloader.so` грузится из `<clinit>` класса `JNILib` раньше движка;
2. в `JNI_OnLoad` запоминаем `jclass JNILib` (из фонового потока его уже
   не найти — там другой classloader);
3. фоновый поток ждёт появления `libag-client.so`, резолвит оригиналы
   через `dlsym` по хендлу библиотеки;
4. `RegisterNatives` переставляет нативные методы на наши обёртки.

Явная регистрация всегда приоритетнее поиска по имени, поэтому механизм не
зависит ни от порядка загрузки библиотек, ни от версии ART, ни от
перестановок кода внутри движка (`libag-client.so` собран с LTO+BOLT, адреса
плывут от сборки к сборке — а экспортируемые JNI-имена нет).

## Что уже есть

* Lua-рантайм на LuaJIT 2.1, по отдельному `lua_State` на скрипт —
  упавший скрипт не утаскивает за собой остальные и тем более игру.
* Модель MoonLoader: `main()` в корутине, `wait(ms)`, события
  `onFrame` / `onImgui` / `onTouch` / `onKey` / `onPause` / `onResume` /
  `onScriptTerminate`.
* ImGui-оверлей поверх игры с плавающей кнопкой вызова (её можно
  перетаскивать или вовсе убрать), встроенным менеджером скриптов,
  консолью лога и списком модулей.
* Чат-команды: `registerChatCommand` и `sendChat` — перехват идёт через
  `GTASA.OnInputEnd`, куда игровая клавиатура отдаёт отправленную строку.
* `imgui.*` из Lua — окна, виджеты, вкладки и рисование поверх всего
  (`DrawLine`/`DrawRect`/`DrawText` — то, что нужно для ESP).
* `memory.*` — чтение/запись через `process_vm_readv/writev` (неверный адрес
  возвращает ошибку, а не роняет игру) и `memory.scan` — поиск по сигнатуре.
* `ffi` из LuaJIT доступен как есть: найденный адрес можно объявить
  прототипом и вызвать.

## Чего нет и не будет «само»

Движок закрыт: у нас есть кадр, ввод, экран и произвольный доступ к памяти —
но **нет** имён игровых функций и структур. Поэтому:

* нет `game.*`, опкодов и совместимости с MoonLoader/MonetLoader-скриптами —
  в новом движке нет SCM-машины, к которой они обращаются;
* нет `sampev`/`sampfuncs` — RakNet выкинут, сеть на boost.asio со своим
  протоколом (`libPED::RPC::*`);
* координаты игрока, ники, транспорт и прочее придётся находить
  самостоятельно через `memory.scan` и `ffi`.

Скрипт `scripts/02_memory.lua` — как раз инструмент для этого: сканер
сигнатур и hex-просмотрщик, не выходя из игры.

## Сборка

Нужен Android NDK r25+.

```bash
cd agloader
./build.sh                       # обе ABI, Release -> dist/<abi>/
./build.sh --ndk /path/to/ndk    # если ANDROID_NDK_HOME не задан
```

Без NDK под рукой — соберите в GitHub Actions: вкладка **Actions →
agloader → Run workflow**. Workflow собирает обе ABI, а если указать тег
релиза, ещё и встроит загрузчик в APK и подпишет — на выходе готовый к
установке файл артефактом.

Проверить, что код компилируется, можно и без NDK:

```bash
sudo apt-get install -y g++-aarch64-linux-gnu libgles-dev libegl-dev
./hostcheck.sh
```

(`hostcheck.sh` собирает под aarch64 с glibc-заголовками — это проверка
синтаксиса и кодогенерации, полученные объектники на устройстве нерабочие.)

## Установка в APK

```bash
python3 ../tools/inject_native_lib.py \
    --apk ARIZONA.ONLINE_v17.7.1.apk \
    --out ARIZONA.ONLINE_v17.7.1_agloader.apk \
    --load luajit-5.1 --load agloader \
    --lib arm64-v8a=dist/arm64-v8a/libluajit-5.1.so \
    --lib arm64-v8a=dist/arm64-v8a/libagloader.so \
    --smali smali.jar --baksmali baksmali.jar
```

APK на выходе не подписан — подпишите `apksigner`/`uber-apk-signer` или
откройте и сохраните в MT Manager.

Скрипты кладутся на устройство сюда:

```
/sdcard/Android/media/com.arizonagames.arizona.web/agloader/
├── scripts/   *.lua — грузятся при старте. Кладите свои сюда
├── lib/       ваши Lua-модули для require и .so для package.cpath
├── config/    ваши конфиги, загрузчик сюда ничего не пишет
└── logs/agloader.log
```

Загрузчик создаёт все четыре каталога пустыми при первом запуске и сам
ничего в них не кладёт. **`lib/` пустой — так и задумано**: свои библиотеки
загрузчик держит внутри APK (`libagloader.so`, `libluajit-5.1.so`), а этот
каталог существует для *ваших* Lua-модулей. Он прописан в `package.path`
и `package.cpath`, поэтому файл `lib/mylib.lua` подключается как
`require('mylib')`.

Каталог `Android/media` пишется обычным файловым менеджером без рута и без
особых разрешений.

Примеры скриптов лежат в `scripts/` этого репозитория, а в CI выкладываются
артефактом **`agloader-scripts`** — их удобно скачать прямо на телефон и
распаковать в `agloader/scripts/`. Начните с `03_test.lua`: он по очереди
проверяет всё, что умеет загрузчик.

## Lua API

### Общее

```lua
script_name(s) / script_author(s) / script_version(s)
thisScript()          -- таблица: id, name, author, version, filename, path
wait(ms)              -- только внутри main(); wait(-1) — уснуть навсегда
log(...)              -- в agloader.log и в консоль меню (print — то же самое)
getScreenSize()       -- w, h
getFrameTime()        -- секунды на прошлый кадр
getFrameCount()
getPaths()            -- root/scripts/lib/config/logs/package
reloadScripts()
isMenuOpen() / setMenuOpen(bool)
loaderVersion()
```

### События

```lua
function main() end                       -- корутина, живёт между wait()
function onFrame(dt) end                  -- каждый кадр
function onImgui() end                    -- рисование, только тут работает imgui.*
function onTouch(action, id, x, y) end    -- вернуть false = поглотить
function onKey(code, action) end          -- вернуть false = поглотить
function onPause() end
function onResume() end
function onScriptTerminate() end
```

`action` в `onTouch` — это `MotionEvent.getActionMasked()`:
`0` DOWN, `1` UP, `2` MOVE, `3` CANCEL, `5` POINTER_DOWN, `6` POINTER_UP.
Движок отдаёт координаты только пальцев с id 0..2.

### Чат

Чат перехватывается через `GTASA.OnInputEnd(String)` — метод, в который
игровая клавиатура отдаёт отправленную строку. Команда, которую разобрал
скрипт, до сервера не доходит.

```lua
registerChatCommand('stmenu', function(args)  -- args — всё после имени
  show = not show
end)
unregisterChatCommand('stmenu')

sendChat('/time')     -- отправить строку так, будто её напечатал игрок
canSendChat()         -- объект активити ловится из первой отправки чата,
                      -- до неё sendChat вернёт false
```

Имя пишется с `/` или без — разницы нет. Встроенная команда `/agloader`
открывает и закрывает меню загрузчика: если спрятать плавающую кнопку
(галочка в меню), это единственный способ его вернуть.

### memory

```lua
memory.getclientbase()                  -- база и размер libag-client.so
memory.getmodulebase('libbass.so')      -- base, size, path
memory.getmodules()                     -- список {name, path, base, size}

memory.read(addr, size)                 -- строка байтов или nil, err
memory.write(addr, data [, unprotect])  -- true / false, err
memory.readstring(addr [, max])
memory.readi32(addr) / readu32 / readfloat / readdouble / readi8 ... readu64
memory.writei32(addr, v [, unprotect])  -- и остальные по аналогии
memory.isvalid(addr [, size])
memory.protect(addr, size)              -- сделать страницы RWX
memory.hex(addr [, size])
memory.scan(pattern [, module [, n]])   -- addr, offset

memory.regions([only_writable])         -- все отображения из /proc/self/maps
memory.findvalue(value [, type])        -- список адресов, количество
memory.refine(list, value [, type])     -- отсеять список по новому значению
```

`type` — `i8`/`u8`/`i16`/`u16`/`i32`/`u32`/`float`, по умолчанию `i32`.

`findvalue` ищет по областям данных движка: `.data` самой библиотеки плюс
идущие сразу за ней анонимные страницы, где лежит `.bss` (у нового клиента
это 53 МБ и там все глобальные переменные игры). Дальше всё как в Cheat
Engine: нашли текущее значение, дождались, пока оно изменится в игре,
отсеяли `refine` — и так до пары адресов. Готовый пример такого поиска —
`scripts/st_weather.lua`, вкладка «Поиск».

Сигнатура — байты через пробел, `??` — любой байт:
`memory.scan('FD 7B BF A9 ?? ?? 00 91')`.

**Смещение стабильно, адрес — нет.** База `libag-client.so` меняется при
каждом запуске из-за ASLR, поэтому записывайте второе возвращаемое значение
(`offset`) и считайте адрес как `base + offset`.

### imgui

Биндинги в «луашном» стиле — значение туда, значение обратно:

```lua
local changed, value = imgui.Checkbox('вкл', value)
local changed, value = imgui.SliderInt('скорость', value, 0, 100)
local changed, text  = imgui.InputText('ник', text, 64)
```

Есть: `Begin/End`, `BeginChild/EndChild`, `Text`, `TextColored`,
`TextWrapped`, `Button`, `Checkbox`, `RadioButton`, `SliderFloat/Int`,
`DragFloat/Int`, `InputText/Float/Int`, `ColorEdit3`, `Combo`,
`ProgressBar`, `Separator`, `SameLine`, `BeginGroup/EndGroup`,
`CollapsingHeader`, `BeginTabBar/Item`, `SetTooltip`, `IsItemHovered`,
`PushStyleColor/PopStyleColor`, `SetNextWindowPos/Size`, `CalcTextSize`,
константы `WindowFlags_*`, `Cond_*`, `Col_*`.

Рисование поверх всего (foreground draw list, окно не нужно):

```lua
imgui.DrawLine(x1, y1, x2, y2, r, g, b, a [, thickness])
imgui.DrawRect(x1, y1, x2, y2, r, g, b, a [, thickness])
imgui.DrawRectFilled(x1, y1, x2, y2, r, g, b, a)
imgui.DrawCircle(x, y, radius, r, g, b, a [, thickness])
imgui.DrawCircleFilled(x, y, radius, r, g, b, a)
imgui.DrawText(x, y, text, r, g, b, a)
```

Если скрипт упал между `Begin` и `End`, загрузчик сам закрывает всё, что тот
открыл, — один сломанный скрипт не ломает кадр остальным.

### ffi

LuaJIT'овский `ffi` доступен без ограничений. Найденный адрес объявляется
прототипом и вызывается напрямую:

```lua
local ffi = require('ffi')
ffi.cdef[[ float ag_get_speed(void* self); ]]
local base = memory.getclientbase()
local fn = ffi.cast('float(*)(void*)', base + 0x123456)
```

## Лицензия

GPL-3.0-or-later. Сторонние компоненты: Dear ImGui (MIT), LuaJIT (MIT) —
их лицензии лежат рядом в `third_party/`.
