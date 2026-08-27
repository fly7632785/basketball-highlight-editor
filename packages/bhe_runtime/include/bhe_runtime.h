#ifndef BHE_RUNTIME_H
#define BHE_RUNTIME_H

#include <stdbool.h>
#include <stdint.h>

typedef struct RuntimeSession RuntimeSession;

bool bhe_runtime_initialize_onnx(const char *library_path);
RuntimeSession *bhe_runtime_create_session(const char *config);
char *bhe_runtime_push_frame(RuntimeSession *session, const char *frame);
/*
 * Processes one raw RGBA video frame (no JPEG/base64/JSON overhead).
 * rgba_data must contain width * height * 4 bytes in RGBA row-major order.
 * Caller retains ownership of rgba_data; the runtime copies it before returning.
 */
char *bhe_runtime_push_frame_raw(
    RuntimeSession *session,
    int64_t time_ms,
    uint32_t width,
    uint32_t height,
    const uint8_t *rgba_data,
    int64_t rgba_len
);
void bhe_runtime_free_session(RuntimeSession *session);
char *bhe_runtime_analyze_json(const char *input);
char *bhe_runtime_version(void);
void bhe_runtime_free_string(char *value);

#endif
