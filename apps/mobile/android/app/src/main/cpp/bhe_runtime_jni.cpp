#include <jni.h>
#include <cstdlib>
#include <android/bitmap.h>
#include <android/log.h>
#include <cstdint>

#define BHE_LOGI(...) __android_log_print(ANDROID_LOG_INFO, "BHE-NativeRuntime", __VA_ARGS__)
#define BHE_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "BHE-NativeRuntime", __VA_ARGS__)

extern "C" {
void* bhe_runtime_create_session(const char* config);
char* bhe_runtime_session_info(void* session);
bool bhe_runtime_initialize_onnx(const char* library_path);
char* bhe_runtime_push_frame(void* session, const char* frame);
char* bhe_runtime_push_frame_raw(
    void* session,
    int64_t time_ms,
    uint32_t width,
    uint32_t height,
    const uint8_t* rgba_data,
    int64_t rgba_len
);
char* bhe_runtime_push_frame_raw_strided(
    void* session,
    int64_t time_ms,
    uint32_t width,
    uint32_t height,
    size_t row_stride,
    const uint8_t* rgba_data,
    int64_t rgba_len
);
char* bhe_runtime_push_frame_yuv(
    void* session,
    int64_t time_ms,
    uint32_t width,
    uint32_t height,
    const uint8_t* y,
    size_t y_len,
    size_t y_row_stride,
    size_t y_pixel_stride,
    const uint8_t* u,
    size_t u_len,
    size_t u_row_stride,
    size_t u_pixel_stride,
    const uint8_t* v,
    size_t v_len,
    size_t v_row_stride,
    size_t v_pixel_stride,
    int32_t rotation_degrees
);
void bhe_runtime_free_session(void* session);
char* bhe_runtime_finish_session(void* session);
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

extern "C" JNIEXPORT jstring JNICALL
Java_com_bhe_bhe_1mobile_NativeRuntime_sessionInfo(JNIEnv* env, jclass, jlong session) {
    if (session == 0) return env->NewStringUTF("{\"error\":\"invalid runtime session\"}");
    char* output = bhe_runtime_session_info(reinterpret_cast<void*>(session));
    if (output == nullptr) return env->NewStringUTF("{\"error\":\"runtime returned no session info\"}");
    jstring result = env->NewStringUTF(output);
    bhe_runtime_free_string(output);
    return result;
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

extern "C" JNIEXPORT jstring JNICALL
Java_com_bhe_bhe_1mobile_NativeRuntime_pushFrameRaw(
    JNIEnv* env,
    jclass,
    jlong session,
    jlong timeMs,
    jint width,
    jint height,
    jbyteArray rgba
) {
    if (session == 0 || rgba == nullptr || width <= 0 || height <= 0) {
        BHE_LOGE("pushFrameRaw invalid session, dimensions, or pixel buffer");
        return env->NewStringUTF("{\"error\":\"invalid raw frame\"}");
    }
    const jsize length = env->GetArrayLength(rgba);
    const int64_t expected = static_cast<int64_t>(width) * height * 4;
    if (length != expected) {
        BHE_LOGE("pushFrameRaw invalid buffer length=%d expected=%lld", length, static_cast<long long>(expected));
        return env->NewStringUTF("{\"error\":\"invalid raw frame length\"}");
    }
    jbyte* bytes = env->GetByteArrayElements(rgba, nullptr);
    if (bytes == nullptr) {
        return env->NewStringUTF("{\"error\":\"unable to read raw frame\"}");
    }
    char* output = bhe_runtime_push_frame_raw(
        reinterpret_cast<void*>(session),
        static_cast<int64_t>(timeMs),
        static_cast<uint32_t>(width),
        static_cast<uint32_t>(height),
        reinterpret_cast<const uint8_t*>(bytes),
        static_cast<int64_t>(length)
    );
    env->ReleaseByteArrayElements(rgba, bytes, JNI_ABORT);
    if (output == nullptr) {
        BHE_LOGE("pushFrameRaw native returned null");
        return env->NewStringUTF("{\"error\":\"runtime returned no response\"}");
    }
    jstring result = env->NewStringUTF(output);
    bhe_runtime_free_string(output);
    return result;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bhe_bhe_1mobile_NativeRuntime_pushFrameYuv(
    JNIEnv* env,
    jclass,
    jlong session,
    jlong timeMs,
    jint width,
    jint height,
    jobject yBuffer,
    jint yOffset,
    jint yLength,
    jint yRowStride,
    jint yPixelStride,
    jobject uBuffer,
    jint uOffset,
    jint uLength,
    jint uRowStride,
    jint uPixelStride,
    jobject vBuffer,
    jint vOffset,
    jint vLength,
    jint vRowStride,
    jint vPixelStride,
    jint rotationDegrees
) {
    if (session == 0 || width <= 0 || height <= 0 || yBuffer == nullptr || uBuffer == nullptr || vBuffer == nullptr ||
        yRowStride <= 0 || uRowStride <= 0 || vRowStride <= 0 || yPixelStride <= 0 || uPixelStride <= 0 || vPixelStride <= 0) {
        return env->NewStringUTF("{\"error\":\"invalid YUV frame\"}");
    }
    const jlong yCapacity = env->GetDirectBufferCapacity(yBuffer);
    const jlong uCapacity = env->GetDirectBufferCapacity(uBuffer);
    const jlong vCapacity = env->GetDirectBufferCapacity(vBuffer);
    if (yCapacity < 0 || uCapacity < 0 || vCapacity < 0 ||
        yOffset < 0 || uOffset < 0 || vOffset < 0 ||
        yLength < 0 || uLength < 0 || vLength < 0 ||
        static_cast<jlong>(yOffset) + yLength > yCapacity ||
        static_cast<jlong>(uOffset) + uLength > uCapacity ||
        static_cast<jlong>(vOffset) + vLength > vCapacity) {
        BHE_LOGE("pushFrameYuv invalid plane bounds: y=%d+%d/%lld u=%d+%d/%lld v=%d+%d/%lld",
            yOffset, yLength, static_cast<long long>(yCapacity),
            uOffset, uLength, static_cast<long long>(uCapacity),
            vOffset, vLength, static_cast<long long>(vCapacity));
        return env->NewStringUTF("{\"error\":\"invalid YUV plane bounds\"}");
    }
    auto plane = [&](jobject buffer, jint offset) -> const uint8_t* {
        auto* address = static_cast<const uint8_t*>(env->GetDirectBufferAddress(buffer));
        return address == nullptr ? nullptr : address + offset;
    };
    const auto* y = plane(yBuffer, yOffset);
    const auto* u = plane(uBuffer, uOffset);
    const auto* v = plane(vBuffer, vOffset);
    if (y == nullptr || u == nullptr || v == nullptr) {
        return env->NewStringUTF("{\"error\":\"YUV plane is not a direct buffer\"}");
    }
    const auto requiredPlaneBytes = [](jint planeWidth, jint planeHeight, jint rowStride, jint pixelStride) -> jlong {
        if (planeWidth <= 0 || planeHeight <= 0 || rowStride <= 0 || pixelStride <= 0) return -1;
        return static_cast<jlong>(planeHeight - 1) * rowStride + static_cast<jlong>(planeWidth - 1) * pixelStride + 1;
    };
    const jlong requiredY = requiredPlaneBytes(width, height, yRowStride, yPixelStride);
    const jlong requiredU = requiredPlaneBytes((width + 1) / 2, (height + 1) / 2, uRowStride, uPixelStride);
    const jlong requiredV = requiredPlaneBytes((width + 1) / 2, (height + 1) / 2, vRowStride, vPixelStride);
    if (requiredY < 0 || requiredU < 0 || requiredV < 0 ||
        yLength < requiredY || uLength < requiredU || vLength < requiredV) {
        BHE_LOGE("pushFrameYuv plane payload too small: y=%d/%lld u=%d/%lld v=%d/%lld",
            yLength, static_cast<long long>(requiredY), uLength, static_cast<long long>(requiredU),
            vLength, static_cast<long long>(requiredV));
        return env->NewStringUTF("{\"error\":\"YUV plane payload too small\"}");
    }
    char* output = bhe_runtime_push_frame_yuv(
        reinterpret_cast<void*>(session), static_cast<int64_t>(timeMs),
        static_cast<uint32_t>(width), static_cast<uint32_t>(height),
        y, static_cast<size_t>(yLength),
        static_cast<size_t>(yRowStride), static_cast<size_t>(yPixelStride),
        u, static_cast<size_t>(uLength),
        static_cast<size_t>(uRowStride), static_cast<size_t>(uPixelStride),
        v, static_cast<size_t>(vLength),
        static_cast<size_t>(vRowStride), static_cast<size_t>(vPixelStride),
        static_cast<int32_t>(rotationDegrees));
    if (output == nullptr) return env->NewStringUTF("{\"error\":\"runtime returned no response\"}");
    jstring result = env->NewStringUTF(output);
    bhe_runtime_free_string(output);
    return result;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_bhe_bhe_1mobile_NativeRuntime_pushFrameBitmap(
    JNIEnv* env,
    jclass,
    jlong session,
    jlong timeMs,
    jobject bitmap
) {
    if (session == 0 || bitmap == nullptr) {
        return env->NewStringUTF("{\"error\":\"invalid bitmap frame\"}");
    }
    AndroidBitmapInfo info{};
    const int infoResult = AndroidBitmap_getInfo(env, bitmap, &info);
    if (infoResult != ANDROID_BITMAP_RESULT_SUCCESS || info.format != ANDROID_BITMAP_FORMAT_RGBA_8888 || info.width == 0 || info.height == 0) {
        BHE_LOGE("pushFrameBitmap invalid bitmap info result=%d format=%u", infoResult, info.format);
        return env->NewStringUTF("{\"error\":\"bitmap must be RGBA_8888\"}");
    }
    void* pixels = nullptr;
    const int lockResult = AndroidBitmap_lockPixels(env, bitmap, &pixels);
    if (lockResult != ANDROID_BITMAP_RESULT_SUCCESS || pixels == nullptr) {
        BHE_LOGE("pushFrameBitmap lock failed result=%d width=%u height=%u stride=%u isNull=%s", lockResult, info.width, info.height, info.stride, pixels == nullptr ? "true" : "false");
        return env->NewStringUTF("{\"error\":\"unable to lock bitmap pixels\"}");
    }
    char* output = bhe_runtime_push_frame_raw_strided(
        reinterpret_cast<void*>(session),
        static_cast<int64_t>(timeMs),
        info.width,
        info.height,
        info.stride,
        reinterpret_cast<const uint8_t*>(pixels),
        static_cast<int64_t>(info.stride) * info.height
    );
    AndroidBitmap_unlockPixels(env, bitmap);
    if (output == nullptr) {
        BHE_LOGE("pushFrameBitmap native returned null");
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

extern "C" JNIEXPORT jstring JNICALL
Java_com_bhe_bhe_1mobile_NativeRuntime_finishSession(JNIEnv* env, jclass, jlong session) {
    if (session == 0) return env->NewStringUTF("{\"error\":\"invalid runtime session\"}");
    char* output = bhe_runtime_finish_session(reinterpret_cast<void*>(session));
    if (output == nullptr) return env->NewStringUTF("{\"error\":\"runtime returned no response\"}");
    jstring result = env->NewStringUTF(output);
    bhe_runtime_free_string(output);
    return result;
}
