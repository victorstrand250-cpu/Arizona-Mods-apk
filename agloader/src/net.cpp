// SPDX-License-Identifier: GPL-3.0-or-later
//
// Сеть для скриптов. TLS на Android взять неоткуда, кроме самой системы:
// тащить в загрузчик OpenSSL или mbedtls ради HTTPS — это мегабайты кода и
// свой список корневых сертификатов, который придётся обновлять. Поэтому
// запрос делает java.net.HttpURLConnection через JNI: у него уже есть и TLS,
// и системные сертификаты, и настройки прокси устройства.
//
// Каждый запрос уходит в отдельный поток, а скрипт опрашивает состояние —
// иначе сеть вешала бы поток отрисовки вместе со всей игрой.
#include "net.h"

#include <atomic>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>

#include "loader.h"
#include "log.h"

namespace ag::net {
namespace {

// Больше этого в память не читаем: скрипту столько не нужно, а память
// у игры не резиновая.
constexpr std::size_t kMaxBody = 16u * 1024 * 1024;
constexpr std::size_t kChunk = 32 * 1024;

struct Entry {
  Response resp;
  std::mutex lock;
  std::thread worker;
  std::atomic<bool> finished { false };
};

std::mutex g_lock;
std::unordered_map<int, std::shared_ptr<Entry>> g_entries;
int g_next_id = 1;

// ────────────────────────────────────────────────────── помощники JNI

// Android объявляет AttachCurrentThread(JNIEnv**), JDK — (void**).
// Шаблон выводит тип из подключённого jni.h, и один исходник собирается обоими.
template <typename EnvPtrPtr>
jint attach(JavaVM* vm, jint (JavaVM::*fn)(EnvPtrPtr, void*), JNIEnv** env)
{
  return (vm->*fn)(reinterpret_cast<EnvPtrPtr>(env), nullptr);
}

bool check(JNIEnv* env, std::string* error, const char* where)
{
  if (!env->ExceptionCheck()) {
    return true;
  }
  env->ExceptionClear();
  if (error != nullptr && error->empty()) {
    *error = std::string("ошибка Java в ") + where;
  }
  return false;
}

std::string to_utf8(JNIEnv* env, jstring js)
{
  if (js == nullptr) {
    return {};
  }
  const char* raw = env->GetStringUTFChars(js, nullptr);
  if (raw == nullptr) {
    return {};
  }
  std::string out { raw };
  env->ReleaseStringUTFChars(js, raw);
  return out;
}

// Читает поток целиком. Java отдаёт байты порциями, поэтому крутим цикл.
std::string read_stream(JNIEnv* env, jobject stream, std::string* error)
{
  std::string out;
  if (stream == nullptr) {
    return out;
  }

  jclass is_class = env->GetObjectClass(stream);
  jmethodID read = env->GetMethodID(is_class, "read", "([BII)I");
  jmethodID close = env->GetMethodID(is_class, "close", "()V");
  if (read == nullptr) {
    check(env, error, "InputStream.read");
    return out;
  }

  jbyteArray buf = env->NewByteArray(static_cast<jsize>(kChunk));
  if (buf == nullptr) {
    return out;
  }

  while (true) {
    const jint got = env->CallIntMethod(stream, read, buf, 0,
                                        static_cast<jint>(kChunk));
    if (env->ExceptionCheck()) {
      check(env, error, "чтении ответа");
      break;
    }
    if (got <= 0) {
      break;
    }
    const std::size_t want = static_cast<std::size_t>(got);
    if (out.size() + want > kMaxBody) {
      if (error != nullptr && error->empty()) {
        *error = "ответ слишком большой";
      }
      break;
    }
    const std::size_t at = out.size();
    out.resize(at + want);
    env->GetByteArrayRegion(buf, 0, got,
                            reinterpret_cast<jbyte*>(&out[at]));
  }

  if (close != nullptr) {
    env->CallVoidMethod(stream, close);
    if (env->ExceptionCheck()) {
      env->ExceptionClear();
    }
  }
  env->DeleteLocalRef(buf);
  return out;
}

void collect_headers(JNIEnv* env, jclass conn_class, jobject conn,
                     std::map<std::string, std::string>* out)
{
  jmethodID key_m = env->GetMethodID(conn_class, "getHeaderFieldKey",
                                     "(I)Ljava/lang/String;");
  jmethodID val_m = env->GetMethodID(conn_class, "getHeaderField",
                                     "(I)Ljava/lang/String;");
  if (key_m == nullptr || val_m == nullptr) {
    if (env->ExceptionCheck()) {
      env->ExceptionClear();
    }
    return;
  }

  for (jint i = 0; i < 64; ++i) {
    jstring key = static_cast<jstring>(env->CallObjectMethod(conn, key_m, i));
    jstring val = static_cast<jstring>(env->CallObjectMethod(conn, val_m, i));
    if (env->ExceptionCheck()) {
      env->ExceptionClear();
      break;
    }
    if (key == nullptr && val == nullptr) {
      break;  // заголовки кончились
    }
    if (key != nullptr) {
      std::string k = to_utf8(env, key);
      // Приводим к нижнему регистру: заголовки регистронезависимы, а скрипту
      // удобнее обращаться по одному написанию.
      for (auto& c : k) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
      }
      (*out)[k] = to_utf8(env, val);
      env->DeleteLocalRef(key);
    }
    if (val != nullptr) {
      env->DeleteLocalRef(val);
    }
  }
}

void run_request(std::shared_ptr<Entry> entry, Request req)
{
  Response resp;
  resp.state = State::Failed;

  JavaVM* vm = loader::vm();
  JNIEnv* env = nullptr;
  if (vm == nullptr ||
      attach(vm, &JavaVM::AttachCurrentThread, &env) != JNI_OK ||
      env == nullptr) {
    resp.error = "не удалось подключить поток к JVM";
    std::lock_guard<std::mutex> guard { entry->lock };
    entry->resp = std::move(resp);
    entry->finished.store(true);
    return;
  }

  // Локальные ссылки складываем в один кадр и разом освобождаем.
  if (env->PushLocalFrame(64) != JNI_OK) {
    resp.error = "не хватило места под ссылки JNI";
    vm->DetachCurrentThread();
    std::lock_guard<std::mutex> guard { entry->lock };
    entry->resp = std::move(resp);
    entry->finished.store(true);
    return;
  }

  do {
    jclass url_class = env->FindClass("java/net/URL");
    if (url_class == nullptr) {
      check(env, &resp.error, "поиске java.net.URL");
      break;
    }
    jmethodID url_ctor = env->GetMethodID(url_class, "<init>",
                                          "(Ljava/lang/String;)V");
    jstring jurl = env->NewStringUTF(req.url.c_str());
    jobject url = env->NewObject(url_class, url_ctor, jurl);
    if (!check(env, &resp.error, "разборе адреса") || url == nullptr) {
      if (resp.error.empty()) {
        resp.error = "неверный адрес";
      }
      break;
    }

    jmethodID open = env->GetMethodID(url_class, "openConnection",
                                      "()Ljava/net/URLConnection;");
    jobject conn = env->CallObjectMethod(url, open);
    if (!check(env, &resp.error, "открытии соединения") || conn == nullptr) {
      if (resp.error.empty()) {
        resp.error = "соединение не открылось";
      }
      break;
    }

    jclass conn_class = env->FindClass("java/net/HttpURLConnection");
    if (conn_class == nullptr || !env->IsInstanceOf(conn, conn_class)) {
      resp.error = "адрес не http и не https";
      break;
    }

    env->CallVoidMethod(conn, env->GetMethodID(conn_class, "setRequestMethod",
                                               "(Ljava/lang/String;)V"),
                        env->NewStringUTF(req.method.c_str()));
    if (!check(env, &resp.error, "выборе метода")) {
      break;
    }

    jmethodID set_ct = env->GetMethodID(conn_class, "setConnectTimeout", "(I)V");
    jmethodID set_rt = env->GetMethodID(conn_class, "setReadTimeout", "(I)V");
    env->CallVoidMethod(conn, set_ct, static_cast<jint>(req.timeout_ms));
    env->CallVoidMethod(conn, set_rt, static_cast<jint>(req.timeout_ms));

    jmethodID set_prop = env->GetMethodID(
        conn_class, "setRequestProperty",
        "(Ljava/lang/String;Ljava/lang/String;)V");
    for (const auto& kv : req.headers) {
      env->CallVoidMethod(conn, set_prop,
                          env->NewStringUTF(kv.first.c_str()),
                          env->NewStringUTF(kv.second.c_str()));
      if (env->ExceptionCheck()) {
        env->ExceptionClear();
      }
    }

    if (!req.body.empty()) {
      env->CallVoidMethod(conn, env->GetMethodID(conn_class, "setDoOutput",
                                                 "(Z)V"),
                          JNI_TRUE);
      jobject os = env->CallObjectMethod(
          conn, env->GetMethodID(conn_class, "getOutputStream",
                                 "()Ljava/io/OutputStream;"));
      if (!check(env, &resp.error, "открытии потока записи") || os == nullptr) {
        if (resp.error.empty()) {
          resp.error = "не удалось отправить тело запроса";
        }
        break;
      }
      jbyteArray data = env->NewByteArray(static_cast<jsize>(req.body.size()));
      env->SetByteArrayRegion(
          data, 0, static_cast<jsize>(req.body.size()),
          reinterpret_cast<const jbyte*>(req.body.data()));
      jclass os_class = env->GetObjectClass(os);
      env->CallVoidMethod(os, env->GetMethodID(os_class, "write", "([B)V"), data);
      env->CallVoidMethod(os, env->GetMethodID(os_class, "close", "()V"));
      if (!check(env, &resp.error, "отправке тела")) {
        break;
      }
    }

    const jint code = env->CallIntMethod(
        conn, env->GetMethodID(conn_class, "getResponseCode", "()I"));
    if (!check(env, &resp.error, "получении кода ответа")) {
      break;
    }
    resp.code = static_cast<int>(code);

    collect_headers(env, conn_class, conn, &resp.headers);

    // При коде 4xx/5xx тело лежит в потоке ошибок, а не в обычном.
    const char* stream_name = (code >= 400) ? "getErrorStream" : "getInputStream";
    jobject stream = env->CallObjectMethod(
        conn, env->GetMethodID(conn_class, stream_name,
                               "()Ljava/io/InputStream;"));
    if (env->ExceptionCheck()) {
      env->ExceptionClear();
      stream = nullptr;
    }
    if (stream != nullptr) {
      resp.body = read_stream(env, stream, &resp.error);
    }

    env->CallVoidMethod(conn, env->GetMethodID(conn_class, "disconnect", "()V"));
    if (env->ExceptionCheck()) {
      env->ExceptionClear();
    }

    resp.state = State::Done;
  } while (false);

  env->PopLocalFrame(nullptr);
  vm->DetachCurrentThread();

  std::lock_guard<std::mutex> guard { entry->lock };
  entry->resp = std::move(resp);
  entry->finished.store(true);
}

}  // namespace

int start(const Request& req)
{
  if (req.url.empty()) {
    return 0;
  }

  auto entry = std::make_shared<Entry>();
  int id = 0;
  {
    std::lock_guard<std::mutex> guard { g_lock };
    id = g_next_id++;
    g_entries[id] = entry;
  }

  entry->worker = std::thread(run_request, entry, req);
  entry->worker.detach();
  return id;
}

State poll(int id)
{
  std::shared_ptr<Entry> entry;
  {
    std::lock_guard<std::mutex> guard { g_lock };
    auto it = g_entries.find(id);
    if (it == g_entries.end()) {
      return State::Failed;
    }
    entry = it->second;
  }
  if (!entry->finished.load()) {
    return State::Running;
  }
  std::lock_guard<std::mutex> guard { entry->lock };
  return entry->resp.state;
}

bool take(int id, Response* out)
{
  std::shared_ptr<Entry> entry;
  {
    std::lock_guard<std::mutex> guard { g_lock };
    auto it = g_entries.find(id);
    if (it == g_entries.end()) {
      return false;
    }
    entry = it->second;
  }
  if (!entry->finished.load()) {
    return false;
  }
  std::lock_guard<std::mutex> guard { entry->lock };
  *out = entry->resp;
  return true;
}

void release(int id)
{
  std::lock_guard<std::mutex> guard { g_lock };
  g_entries.erase(id);
}

std::size_t pending()
{
  std::lock_guard<std::mutex> guard { g_lock };
  std::size_t n = 0;
  for (const auto& kv : g_entries) {
    if (!kv.second->finished.load()) {
      ++n;
    }
  }
  return n;
}

void shutdown()
{
  std::lock_guard<std::mutex> guard { g_lock };
  g_entries.clear();
}

}  // namespace ag::net
