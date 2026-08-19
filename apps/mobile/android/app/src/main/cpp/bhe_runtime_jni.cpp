#include <jni.h>
#include <cstdlib>

extern "C" {
void* bhe_runtime_create_session(const char* config);
char* bhe_runtime_push_frame(void* session, const char* frame);
void bhe_runtime_free_session(void* session);
void bhe_runtime_free_string(char* value);
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bhe_bhe_1mobile_NativeRuntime_createSession(JNIEnv* env, jclass, jstring config) {
    if (config == nullptr) return 0;
    const char* value = env->GetStringUTFChars(config, nullptr);
    void* session = bhe_runtime_create_session(value);
    env->ReleaseStringUTFChars(config, value);
    return reinterpret_cast<jlong>(session);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bhe_bhe_1mobile_NativeRuntime_pushFrame(JNIEnv* env, jclass, jlong session, jstring frame) {
    if (session == 0 || frame == nullptr) return env->NewStringUTF("{\"error\":\"invalid runtime session\"}");
    const char* value = env->GetStringUTFChars(frame, nullptr);
    char* output = bhe_runtime_push_frame(reinterpret_cast<void*>(session), value);
    env->ReleaseStringUTFChars(frame, value);
    if (output == nullptr) return env->NewStringUTF("{\"error\":\"runtime returned no response\"}");
    jstring result = env->NewStringUTF(output);
    bhe_runtime_free_string(output);
    return result;
}

extern "C" JNIEXPORT void JNICALL
Java_com_bhe_bhe_1mobile_NativeRuntime_freeSession(JNIEnv*, jclass, jlong session) {
    if (session != 0) bhe_runtime_free_session(reinterpret_cast<void*>(session));
}
