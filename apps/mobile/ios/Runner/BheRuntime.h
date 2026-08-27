#import <stdbool.h>
#import <stdint.h>

typedef struct RuntimeSession RuntimeSession;

RuntimeSession *bhe_runtime_create_session(const char *config);
char *bhe_runtime_push_frame(RuntimeSession *session, const char *frame);
/*
 * Fast path: raw RGBA pixels, no JPEG/base64/JSON overhead.
 * rgba_data must contain width * height * 4 bytes in row-major order.
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
void bhe_runtime_free_string(char *value);
