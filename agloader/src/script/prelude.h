// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

namespace ag::script {

// Lua-код, который выполняется в каждом состоянии до загрузки самого
// скрипта: lua_thread, привычные имена MoonLoader и мелкие удобства.
const char* prelude_source();

}  // namespace ag::script
