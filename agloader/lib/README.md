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

## Чего здесь нет и не будет

| Модуль | Почему |
|---|---|
| `RakLua` | RakNet из движка выкинут, сеть на boost.asio со своим протоколом |
| `samp*`, `MoonMonet` | нет SA-MP: ни чата SA-MP, ни пула игроков, ни RPC |
| `memory` (MoonLoader) | завязан на 33 нативные функции MoonLoader; в AGLoader своя `memory.*` |
| `requests`, `socket`, `ssl`, `mime`, `copas` | нужны C-модули LuaSocket и OpenSSL |
| `cjson` | C-модуль; вместо него `json` |
| `iconv` | C-модуль; вместо него `encoding` |
| `fAwesome5/6` | это имена иконок, но шрифт загрузчика — системный Roboto, глифов иконок в нём нет |

## Что даёт сам загрузчик

Отдельно подключать не нужно, доступно сразу в любом скрипте:

* `lua_thread.create` / `create_suspended` — фоновые корутины с `wait()`,
  ровно как в MoonLoader;
* `getWorkingDirectory`, `getScriptDirectory`, `getConfigDirectory`,
  `doesFileExist`, `doesDirectoryExist`, `createDirectory`, `deleteFile`;
* `getScreenResolution` (то же, что `getScreenSize`), `getUiScale`;
* `getDistanceBetweenCoords2d/3d`, `round`, `stripColorCodes`;
* `print` уходит в лог загрузчика.
