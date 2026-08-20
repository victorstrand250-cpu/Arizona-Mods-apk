# MonetLoader и новый движок Arizona Mobile — разбор и вывод

Что сравнивалось:

| | старый APK | новый APK |
|---|---|---|
| файл | `ARIZONA MOD_v17.0.3.apk` (release `v1.0`) | `ARIZONA.ONLINE_v17.7.1.apk` (release `Arizona_New`) |
| пакет | `com.arizona.game` | `com.arizonagames.arizona.web` |
| versionCode | 1703 | 1771 |
| targetSdk | 36 | 37 |
| ABI | только `arm64-v8a` | `arm64-v8a` + `armeabi-v7a` |
| движок | `libGTASA.so` (8.9 МБ) + `libsamp.so` (14.3 МБ) + `libarzmod.so` | **`libag-client.so`** (10.2 МБ, один файл) |
| MonetLoader | `libmonetloader.so` + `libluajit-5.1.so` встроены | отсутствует |

Всё, что ниже, воспроизводится скриптом `tools/engine_probe.py`; машиночитаемая
выжимка лежит в `docs/engine-report.json`.

---

## Короткий ответ

**Как есть — не заработает.** Не «частично», не «с багами», а вообще никак:
из 46 символов, которые MonetLoader ищет в игре, в новом движке нет **ни одного**.

Загрузиться в процесс он сможет (см. «Что реально работает уже сейчас»), но
дальше просто ничего не сделает: все хуки останутся пустышками, Lua-рантайм
не запустится, окно не отрисуется.

**Портировать теоретически можно, но это не «встроить», а переписать
загрузчик заново под чужой движок** — работа на месяцы реверса, и часть
функционала (SCM-опкоды, RakNet-хуки) не воспроизводима в принципе, потому что
в новом клиенте этих подсистем физически нет.

---

## Почему именно так

### 1. Аризона не «обновила движок» — она его заменила

Старый клиент — это мобильная GTA:SA от Rockstar (`libGTASA.so`) плюс порт
SA-MP (`libsamp.so`) плюс мод-слой Аризоны (`libarzmod.so`).

Новый `libag-client.so` — собственный клиент, собранный с нуля. По строкам
внутри бинарника видны пути сборки и вендоренные зависимости:

```
/usr/src/vendor/librw/src/engine.cpp        ← librw, открытая реализация RenderWare
/usr/src/vendor/librw/src/gl/gl3raster.cpp
/usr/src/vendor/boost/libs/asio/...         ← сеть на boost.asio
```

плюс статически влинкованные spdlog, EASTL, tinyxml2, FreeType, OpenAL Soft,
mpg123, opus, nlohmann/json. Сборка — clang 17 NDK с `+pgo +bolt +lto`.

Это не пересобранная Rockstar-овская игра. Это переписанный на librw клиент,
который читает часть данных GTA:SA (`data/handling.cfg`, `data/CARCOLS.DAT`,
`DATA\combo.dat`) и добавляет свои форматы (`data/BulletsPreset.json`,
`data/gtasa_weapon_config.dat`, `data/vehicle_shoot.json`).

Java-слой тоже новый: `com.arizonagames.client.game.core.JNILib` с методами
`androidInit/androidStep/androidResize/androidPause/androidResume/
androidKeyEvent/androidMultiTouch`. Старый `com.arizona.game.GTASA` остался,
но только как Activity и как набор UI-биндингов (Cef3D*, HUD, диалоги).

### 2. Символов, за которые цепляется MonetLoader, больше нет

MonetLoader не сканирует память по сигнатурам — он резолвит функции игры
**по именам** через `dlsym()` и свой `plt_scanner`
(см. `MonetLoaderOSS/cpp/main.cpp` → `do_init()`).

Результат проверки `tools/engine_probe.py`:

| группа | что это | старый `libGTASA.so` | новый `libag-client.so` |
|---|---|---|---|
| `hooks` | `CGame::Process`, `CTheScripts::Init/Process`, `CGame::Shutdown`, `CHID::FlushQueuedText`, `_rwOpenGLCameraEndUpdate`, `CRunningScript::Process`, `CWorld::Add/Remove`, `AND_TouchEvent` | **10/10** | **0/10** |
| `common` | `ProcessOneCommand`, `CTouchInterface::IsTouched`, `AsciiToGxtChar`, `CMessages::*`, `CWorld::ProcessLineOfSight`, `CSprite::CalcScreenCoors` | **9/9** | **0/9** |
| `render` | `RwRasterCreate/Lock/Unlock`, `RwImage*`, `RwRenderStateGet/Set`, `RwIm2DRenderIndexedPrimitive_BUGFIX`, `RtPNGImageRead`, `CWidget::SetScissor` | **15/15** | **0/15** |
| `globals` | `CPools::ms_pPedPool/ms_pVehiclePool/ms_pObjectPool`, `CRadar::ms_RadarTrace`, `TheCamera`, `TheText`, `RsGlobal`, `Pads`, `gMobileMenu`, `CTimer::m_UserPause` | **12/12** | **0/12** |
| | **итого** | **46/46** | **0/46** |

Причина: в `libag-client.so` `.dynsym` содержит 4012 определённых символов, и
**все игровые из них отсутствуют** — экспортируется только то, что «протекло»
из статических зависимостей (libc++, spdlog, tinyxml2, fmt, boost, EASTL,
FreeType, OpenAL, mpg123) плюс 39 `Java_*` JNI-точек. `.symtab` вырезан
(binary stripped), код собран с `-fvisibility=hidden` и прогнан через LTO+BOLT,
то есть функции ещё и переупорядочены/заинлайнены относительно исходников.

Для сравнения: у старого `libGTASA.so` — 21646 экспортов с полными
mangled-именами C++, поэтому MonetLoader там и работает «из коробки».

### 3. Пропали целые подсистемы, а не только имена

Даже если найти адреса реверсом, часть MonetLoader переносить некуда:

* **SCM-виртуальной машины нет.** В новом движке нет ни `main.scm`, ни
  `CRunningScript`, ни `CTheScripts`, ни строк `.img`-архивов. А `opcodes.cpp`
  MonetLoader'а — это 8693 строки, которые вызывают
  `CRunningScript::ProcessOneCommand`. На этом стоит весь API `game.*` и
  совместимость с MoonLoader (`0AB1`, `0A8C`, опкоды CLEO). Переносить нечего —
  подсистемы-приёмника не существует.
* **RakNet выкинут.** В `libag-client.so` нет ни одной строки RakNet;
  сеть — на boost.asio с собственным протоколом (видна RTTI-иерархия
  `libPED::RPC::*`: `SyncPedOnFoot`, `ReceivePedSync`, `AddPedToWorld`,
  `EnterToVehicle`, `ApplyPedAnimation` и ещё ~35 классов).
  Значит `rakhook` (609 строк), `sampfuncs`, `onReceiveRpc/onSendPacket`,
  RakLogger и всё, что на них построено, мертво целиком.
* **Рендер другой.** MonetLoader рисует через C-API RenderWare от Rockstar
  (`RwIm2DRenderIndexedPrimitive_BUGFIX`, `RwRasterCreate`). В новом клиенте —
  librw с C++-API в namespace `rw::`. Формально эквиваленты есть
  (`rw::Raster::create`, `rw::im2d::RenderIndexedPrimitive`), но это другие
  сигнатуры и другой стейт-машина, слой `gui/render.cpp` придётся писать заново.
* **Структуры игры поехали.** `CPed`, `CVehicle`, `CPool`, `CEntity` в
  `cpp/game/*.h` — это оффсеты мобильной GTA:SA 2.0/2.1. У переписанного
  клиента раскладка полей своя; `.bss` вырос с 4.9 МБ до 53.8 МБ, что само по
  себе говорит о другой структуре глобальных данных. Всё, что читает игровую
  память (`memory.*`, `SAMemory`, wallhack/bones-скрипты), надо перемерять.

### 4. Чего в новом APK нет — и это хорошая новость

Нативной анти-тамперной защиты в APK не обнаружено. `libsigner.so` — это
signature-библиотека Adjust SDK (аналитика, `Java_com_adjust_sdk_sig_*`),
она есть и в старой сборке. Проверок целостности APK, ptrace/TracerPid,
поиска frida/magisk в бинарнике нет.

Про серверный анти-чит по APK ничего сказать нельзя — он живёт на стороне
Аризоны. Это отдельный риск, не технический.

---

## Что реально работает уже сейчас

Точка внедрения в новый клиент существует и проверена:

```smali
# com/arizonagames/client/game/core/JNILib.smali
.method static constructor <clinit>()V
    .registers 1
    const-string v0, "ag-client"
    invoke-static {v0}, Ljava/lang/System;->loadLibrary(Ljava/lang/String;)V
    return-void
.end method
```

Вставив свой `System.loadLibrary(...)` перед `ag-client`, мы получаем
`JNI_OnLoad` **до** инициализации движка — ровно то место, откуда MonetLoader
и стартует. Это делает `tools/inject_native_lib.py`, и патч проверен на
реальном `ARIZONA.ONLINE_v17.7.1.apk`:

```
[*] класс com/arizonagames/client/game/core/JNILib найден в classes3.dex
[+] monetloader: вставлено в <clinit>, регистр v1 (.registers 1 -> 2)
[*] classes3.dex: 10,435,788 -> 10,543,316 байт
[+] готово: ARIZONA.ONLINE_v17.7.1_monet.apk (177,376,435 байт)
```

Что будет после установки такого APK: `libmonetloader.so` загрузится,
отработает `JNI_OnLoad` → `do_preinit()` → `compat::init()`, и загрузчик
уйдёт в фоновый поток `init_thread()`, где вечно ждёт `libGTASA.so`.
Игра при этом стартует нормально: **краша не будет, но и MonetLoader'а не
будет тоже** — ни меню, ни скриптов, ни рендера.

Если через `monetloader/compat/profile.json` подсунуть
`"gtasa_name": "libag-client.so"`, поток разблокируется и дойдёт до
`do_init()`. Там все `dlsym()` вернут `nullptr`; падения тоже не будет, потому
что `monethook::hook::apply()` отсеивает нулевой адрес
(`if (address_ == 0) return result::hook_is_dummy`), — но результат тот же:
все хуки пустые, `lua::script_manager::init()` никогда не вызовется, так как
он висит на хуке `CTheScripts::Process`.

Профиль для такого эксперимента лежит в `tools/profile.new-engine.json`.
Он полезен ровно как способ убедиться своими глазами: посмотреть
`/sdcard/Android/media/com.arizonagames.arizona.web/monetloader/logs/monetloader.log`.

> Оговорка: `libmonetloader.so` из `Monetloader-Base` — сборка с
> зашифрованными строками (в бинарнике нет ни `libGTASA.so`, ни
> `monetloader/`), поэтому по нему нельзя заранее сказать, собран ли он с
> `SAMP_MODE == 2` (тогда при отсутствии `libsamp.so` он делает `exit(0)`
> вместо тихого простоя). Проверяется только запуском.

---

## Что нужно, чтобы порт всё-таки состоялся

Реалистичный порядок работ. Это не «встроить .so в APK», это отдельный проект.

**Этап 0 — плацдарм (готов, см. `tools/`).**
Патч Java-слоя, доставка `.so` в APK, подпись. Сделано и проверено.

**Этап 1 — recon-библиотека.**
Собрать под NDK минимальный `.so`, который логирует базу `libag-client.so`,
дампит `/proc/self/maps`, ловит `androidInit`/`androidStep` через
PLT-хук по JNI-символам (они экспортированы!) и подтверждает, что мы
исполняемся в игровом потоке. `Java_..._JNILib_androidStep` — это фактически
per-frame точка, эквивалент `CGame::Process`. Это единственные легально
доступные якоря в новом движке, и их достаточно для «сердцебиения» загрузчика.

**Этап 2 — карта движка.**
Реверс `libag-client.so` (IDA/Ghidra) с опорой на:
* открытые исходники **librw** — сигнатуры `rw::` функций восстанавливаются
  по строкам ассертов и путям `/usr/src/vendor/librw/src/*.cpp`, вкомпилированным
  в бинарник;
* RTTI-имена `libPED::RPC::*` для сетевого слоя;
* строки конфигов (`data/handling.cfg`, `BulletsPreset.json`) как якоря к
  загрузчикам данных.

Результат — таблица «функция → адрес» для новой версии клиента. Её придётся
переделывать после **каждого** обновления Аризоны, потому что с LTO+BOLT
адреса плывут даже от косметических правок.

**Этап 3 — переписать привязку MonetLoader.**
* `lib_manager` — с `dlsym` на таблицу адресов из этапа 2;
* `gui/render.cpp` — на librw C++ API вместо RW C API;
* `cpp/game/*.h` — заново снять оффсеты структур;
* `script/opcodes.cpp` — **выбросить или заменить**: SCM-машины нет;
* `game/rakhook.cpp`, `netinfo` — **выбросить или переписать** под
  `libPED`-протокол на boost.asio.

**Этап 4 — совместимость скриптов.**
После этапа 3 существующие Lua-скрипты в массе своей не заведутся: они
написаны против `game.*` (SCM) и `sampev`/`sampfuncs` (RakNet). Придётся либо
писать слой эмуляции, либо признать, что это новый загрузчик с новым API.

Честная оценка: этапы 1–2 — недели плотного реверса, этап 3 — месяцы, этап 4
— переписывание экосистемы скриптов. И всё это ломается на каждом обновлении
клиента.

---

## Практический вывод

1. Встроить MonetLoader в новый движок «как есть» **нельзя** — 0 из 46
   необходимых символов.
2. Инъекция в процесс — **решённая задача**, инструмент готов и проверен.
   Всё остальное упирается в реверс закрытого движка.
3. Пока порта нет, единственный рабочий вариант — держать старую сборку
   на старом движке. Она в релизе `v1.0` и работает.
4. Если браться за порт — начинать надо с этапа 1 (recon через JNI-якоря
   `androidInit`/`androidStep`), потому что это единственная документально
   доступная точка входа в новый клиент.

## Ссылки

* `tools/README.md` — как пользоваться инструментами
* `docs/engine-report.json` — сырой отчёт по трём библиотекам
* MonetLoaderOSS: https://github.com/xefinity/MonetLoaderOSS
* librw: https://github.com/aap/librw
