# tools

Два скрипта для работы с APK Arizona Mobile. Нужен только Python 3 и Java.
Разбор выводов — в [`../docs/MONETLOADER_NEW_ENGINE.md`](../docs/MONETLOADER_NEW_ENGINE.md).

## engine_probe.py

Смотрит нативный движок и отвечает на вопрос «заведётся ли тут MonetLoader».
Проверяет наличие всех 46 символов, которые загрузчик резолвит через `dlsym`,
и определяет, из чего движок собран.

```bash
python3 tools/engine_probe.py lib/arm64-v8a/libGTASA.so
python3 tools/engine_probe.py --apk ARIZONA.ONLINE_v17.7.1.apk --json report.json
```

```
=== libag-client.so
    размер:            10,219,736 байт
    .symtab отсутств.: True (stripped)
    .dynsym:           4012 определённых, 457 внешних
    собран из:         librw (open-source RenderWare), boost.asio, spdlog, EASTL, ...

    Символы, которые MonetLoader резолвит в libGTASA.so:
      hooks    0/10
      common   0/9
      render   0/15
      globals  0/12
    ИТОГО: 0/46 — MonetLoader НЕ заработает как есть
```

Скрипт стоит прогонять после каждого обновления Аризоны: он сразу скажет,
не вернули ли обратно экспорты.

## inject_native_lib.py

Встраивает `.so` в APK и добавляет `System.loadLibrary()` в `<clinit>` нужного
класса, чтобы библиотека грузилась **раньше** движка.

Правит **только один** `classes*.dex` (тот, где лежит класс) и пересобирает zip,
не трогая остальные записи — ресурсы и `resources.arsc` остаются байт-в-байт
исходными. Это безопаснее полного круга `apktool d` / `apktool b`.
STORED-записи выравниваются как `zipalign` (4 байта, `.so` — 4096), иначе
Android с targetSdk ≥ 30 откажется ставить APK.

Нужны `smali.jar` и `baksmali.jar` версии 2.5.x —
https://bitbucket.org/JesusFreke/smali/downloads/

```bash
python3 tools/inject_native_lib.py \
    --apk ARIZONA.ONLINE_v17.7.1.apk \
    --out ARIZONA.ONLINE_v17.7.1_monet.apk \
    --load monetloader \
    --lib arm64-v8a=libmonetloader.so \
    --lib arm64-v8a=libluajit-5.1.so \
    --smali tools/smali.jar --baksmali tools/baksmali.jar
```

Точки внедрения:

| APK | `--class` | что там |
|---|---|---|
| новый движок (по умолчанию) | `com/arizonagames/client/game/core/JNILib` | `loadLibrary("ag-client")` |
| старый движок | `com/arzmod/radare/InitGamePatch` | `loadLib("GTASA"/"samp"/"monetloader")` |

APK на выходе **не подписан** (старая v1-подпись удаляется, v2/v3-блок
теряется при пересборке zip). Подпишите `apksigner`, `uber-apk-signer`
или просто откройте и сохраните в MT Manager.

## profile.new-engine.json

Compat-профиль MonetLoader, нацеленный на `libag-client.so`. Кладётся в

```
/sdcard/Android/media/com.arizonagames.arizona.web/monetloader/compat/profile.json
```

Нужен **не для работы**, а для проверки: с ним загрузчик перестаёт вечно ждать
`libGTASA.so`, доходит до `do_init()` и пишет лог в
`.../monetloader/logs/monetloader.log`. Все хуки при этом останутся пустыми —
почему, написано в отчёте.
