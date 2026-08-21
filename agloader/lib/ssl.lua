-- Заглушка LuaSec.
--
-- Скрипты подключают ssl только ради ssl.https, и он есть — настоящий, на
-- системном стеке Android. Всё остальное из LuaSec (обёртка сокета в TLS,
-- работа с сертификатами) требует OpenSSL, которого в загрузчике нет.
local ssl = {}

ssl._VERSION = 'AGLoader ssl (только https)'
ssl.https = require 'ssl.https'

setmetatable(ssl, { __index = function(_, k)
  error('ssl.' .. tostring(k) .. ' недоступен: в загрузчике нет OpenSSL. ' ..
        'Для HTTPS используйте ssl.https или socket.http', 2)
end })

return ssl
