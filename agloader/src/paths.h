// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <string>

namespace ag::paths {

// Определяет имя пакета по /proc/self/cmdline и раскладывает каталоги:
//   /sdcard/Android/media/<package>/agloader/{scripts,lib,config,logs}
// Каталог media доступен на запись без разрешений начиная с Android 10,
// поэтому пользователь может закинуть туда скрипты обычным файловым менеджером.
// Возвращает false, если создать каталоги не удалось.
bool init();

const std::string& package();  // com.arizonagames.arizona.web
const std::string& root();     // .../agloader
const std::string& scripts();  // .../agloader/scripts
const std::string& lua_lib();  // .../agloader/lib
const std::string& config();   // .../agloader/config
const std::string& logs();     // .../agloader/logs

}  // namespace ag::paths
