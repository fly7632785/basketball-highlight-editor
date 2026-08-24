#include <jni.h>
#include <cstdlib>
#include <android/log.h>

#define BHE_LOGI(...) __android_log_print(ANDROID_LOG_INFO, "BHE-NativeRuntime", __VA_ARGS__)
#define BHE_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "BHE-NativeRuntime", __VA_ARGS__)

extern "C" {
void* bhe_runtime_create_session(const char* config);
bool bhe_runtime_initialize_onnx(const char* library_path);
char* bhe_runtime_push_frame(void* session, const char* frame);
void bhe_runtime_free_session(void* session);
void bhe_runtime_free_string(char* value);
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_bhe_bhe_1mobile_NativeRuntime_createSession(JNIEnv* env, jclass, jstring config) {
    if (config == nullptr) {
        BHE_LOGE("createSession called with null config");
        return 0;
    }
    const char* value = env->GetStringUTFChars(config, nullptr);
    BHE_LOGI("createSession native start");
    void* session = bhe_runtime_create_session(value);
    env->ReleaseStringUTFChars(config, value);
    BHE_LOGI("createSession native returned %p", session);
    return reinterpret_cast<jlong>(session);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_bhe_bhe_1mobile_NativeRuntime_initializeOnnx(JNIEnv* env, jclass, jstring libraryPath) {
    const char* value = nullptr;
    if (libraryPath != nullptr) value = env->GetStringUTFChars(libraryPath, nullptr);
    BHE_LOGI("initializeOnnx start path=%s", value == nullptr ? "<already loaded>" : value);
    const bool initialized = bhe_runtime_initialize_onnx(value);
    if (libraryPath != nullptr) env->ReleaseStringUTFChars(libraryPath, value);
    BHE_LOGI("initializeOnnx returned=%s", initialized ? "true" : "false");
    return initialized ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bhe_bhe_1mobile_NativeRuntime_pushFrame(JNIEnv* env, jclass, jlong session, jstring frame) {
    if (session == 0 || frame == nullptr) {
        BHE_LOGE("pushFrame invalid session or frame");
        return env->NewStringUTF("{\"error\":\"invalid runtime session\"}");
    }
    const char* value = env->GetStringUTFChars(frame, nullptr);
    char* output = bhe_runtime_push_frame(reinterpret_cast<void*>(session), value);
    env->ReleaseStringUTFChars(frame, value);
    if (output == nullptr) {
        BHE_LOGE("pushFrame native returned null");
        return env->NewStringUTF("{\"error\":\"runtime returned no response\"}");
    }
    jstring result = env->NewStringUTF(output);
    bhe_runtime_free_string(output);
    return result;
}

extern "C" JNIEXPORT void JNICALL
Java_com_bhe_bhe_1mobile_NativeRuntime_freeSession(JNIEnv*, jclass, jlong session) {
    if (session != 0) bhe_runtime_free_session(reinterpret_cast<void*>(session));
}
