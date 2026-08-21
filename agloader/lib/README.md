# Библиотеки

Кладутся на устройство в `Android/media/<пакет>/agloader/lib/`. Этот каталог
прописан в `package.path`, поэтому подключаются они обычным `require`:

```lua
local inicfg   = require 'inicfg'
local encoding = require 'encoding'
local json     = require 'json'
```

## Что здесь есть

| Модуль | Откуда | Состояние |
|---|---|---|
| `encoding` | написан для AGLoader | CP1251 ⇄ UTF-8 на чистом Lua |
| `json` | написан для AGLoader | замена `cjson`, encode/decode |
| `inicfg` | MoonLoader (MIT) | как есть |
| `base64` | libstd | как есть |
| `md5` | libstd | как есть |
| `vector3d`, `matrix3x3` | libstd | как есть |
| `binaryheap` | libstd | как есть |
| `ltn12` | LuaSocket (MIT) | как есть |
| `bitex` | libstd | нужен `bit`, он есть в LuaJIT |
| `moonloader` | MoonLoader (MIT) | таблицы констант |
| `sampfuncs` | libstd | таблицы констант |
| `sha1` | libstd | как есть, чистый Lua при отсутствии `bit` |
| `timerwheel` | libstd | как есть |
| `jsoncfg` | libstd (MoonLoader) | как есть, поверх `json` |
| `arizona` | написан для AGLoader | игрок, игроки, пулы сущностей, модели и камера |
| `socket`, `socket.http`, `socket.url` | написаны для AGLoader | сеть в духе LuaSocket |
| `requests` | написан для AGLoader | как в MonetLoader, поверх socket.http |

## encoding

Оригинал держался на C-модуле `iconv`, которого в AGLoader нет, поэтому
написан заново на чистом Lua. Вызовы те же, что привыкли скрипты:

```lua
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8

local utf = u8('\xca\xe0\xec\xe5\xed\xfc')   -- 'Камень' из CP1251 в UTF-8
local cp  = u8:decode(utf)                    -- обратно в CP1251
```

Поддерживаются CP1251 и UTF-8 — для русских скриптов этого достаточно.
Символ, которого в CP1251 нет, при обратном переводе становится `?`, а битая
последовательность UTF-8 не роняет разбор.

## json

Полная замена `cjson` на чистом Lua:

```lua
local json = require 'json'
local t = json.decode('{"a":[1,2,3]}')
local s = json.encode(t, true)     -- true = с отступами
```

Разбор не бросает исключение, а возвращает `nil, текст ошибки` с номером
строки. Ключи объектов при сборке сортируются, поэтому один и тот же конфиг
всегда выглядит одинаково. Пустая таблица кодируется как `{}`; чтобы вышло
`[]`, заверните её в `json.array{}`.

## Сеть

Настоящий LuaSocket — это C-модуль плюс OpenSSL. Здесь вместо них системный
HTTP-стек Android через JNI: у него уже есть TLS, корневые сертификаты и
настройки прокси устройства, так что HTTPS работает без единой лишней
библиотеки.

```lua
local requests = require 'requests'

local r = requests.get('https://api.example.com/data')
if r.ok then
  local t = r.json()
end

requests.post('https://api.example.com/send', { json = { text = 'привет' } })
```

Или ближе к оригиналу:

```lua
local http = require 'socket.http'
local body, code, headers = http.request('https://example.com')
```

Два отличия от LuaSocket, о которых стоит знать:

* **Вызывать только из `main()` или `lua_thread.create`.** Запрос уходит в
  фоновый поток, а вызов ждёт его через `wait()`. Выглядит как обычный
  блокирующий вызов, но поток отрисовки не держит и игра не подвисает. Вне
  корутины вернётся понятная ошибка, а не зависание.
* **Тело запроса — строка**, генераторы `ltn12` не нужны; тело ответа тоже
  возвращается строкой, `sink` не поддерживается.

Сетевая ошибка не роняет скрипт: `requests` вернёт таблицу с полем `error`
и нулевым `status_code`.

Если ответ не нужен прямо сейчас — `requests.async` и `http.async` вернут
номер, а состояние опрашивается через `net.poll` и `net.result`.

## Чего здесь нет и не будет

| Модуль | Почему |
|---|---|
| `RakLua` | RakNet из движка выкинут, сеть на boost.asio со своим протоколом |
| `samp*`, `MoonMonet` | нет SA-MP: ни чата SA-MP, ни пула игроков, ни RPC |
| `memory` (MoonLoader) | завязан на 33 нативные функции MoonLoader; в AGLoader своя `memory.*` |
| `ssl`, `mime`, `copas`, `ltn12`-потоки | завязаны на C-модули LuaSocket; HTTP закрыт своей реализацией выше |
| сырые TCP и UDP сокеты | пока нет: скриптам почти всегда нужен HTTP, а он уже есть |
| `cjson` | C-модуль; вместо него `json` |
| `iconv` | C-модуль; вместо него `encoding` |
| `fAwesome5/6` | это имена иконок, но шрифт загрузчика — системный Roboto, глифов иконок в нём нет |
| `mime` | держится на C-модуле `mime.core`; base64 закрыт своим `base64` |
| `widgets` | номера экранных кнопок старого движка, в новом их нет |

## Что даёт сам загрузчик

Отдельно подключать не нужно, доступно сразу в любом скрипте:

* `lua_thread.create` / `create_suspended` — фоновые корутины с `wait()`,
  ровно как в MoonLoader;
* `getWorkingDirectory`, `getScriptDirectory`, `getConfigDirectory`,
  `doesFileExist`, `doesDirectoryExist`, `createDirectory`, `deleteFile`;
* `getScreenResolution` (то же, что `getScreenSize`), `getUiScale`;
* `getDistanceBetweenCoords2d/3d`, `round`, `stripColorCodes`;
* `print` уходит в лог загрузчика;
* `script.this`, `encodeJson`, `decodeJson`, `setTimer` — их ждут
  библиотеки MoonLoader, поэтому они есть всегда.

## arizona

Всё, что найдено в движке, собрано здесь — отдельно искать адреса не нужно:

```lua
local ag = require 'arizona'

local me = ag.localPlayer()
local x, y, z = ag.position(me)
print(ag.speedKmh(me), ag.inVehicle(me))

for _, p in ipairs(ag.players({ skipLocal = true })) do
  print(p.index, p.x, p.y, p.z, ag.nick(p.index))
end

-- Сущности мира из всех трёх пулов сразу, только рядом с игроком.
for _, e in ipairs(ag.entities({ near = { x, y, z }, radius = 100 })) do
  print(e.poolName, e.index, e.model, e.dist)
end

-- Мировые координаты в экранные — для ESP.
local sx, sy = ag.worldToScreen(e.x, e.y, e.z)
```

Камера и смещения, которые определяются на живой игре, лежат в общем файле
настроек: `ag.saveProjection()` и `ag.loadProjection()`. Подбирает их
`/recon`, а пользуются все скрипты.
