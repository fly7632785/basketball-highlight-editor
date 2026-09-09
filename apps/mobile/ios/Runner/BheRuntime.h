#import <stdbool.h>
#import <stdint.h>
#import <stddef.h>

typedef struct RuntimeSession RuntimeSession;

RuntimeSession *bhe_runtime_create_session(const char *config);
char *bhe_runtime_session_info(RuntimeSession *session);
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
char *bhe_runtime_push_frame_bgra_strided(
    RuntimeSession *session,
    int64_t time_ms,
    uint32_t width,
    uint32_t height,
    size_t row_stride,
    const uint8_t *bgra_data,
    int64_t bgra_len,
    int32_t rotation_degrees
);
char *bhe_runtime_push_frame_yuv(
    RuntimeSession *session,
    int64_t time_ms,
    uint32_t width,
    uint32_t height,
    const uint8_t *y_data,
    size_t y_len,
    size_t y_row_stride,
    size_t y_pixel_stride,
    const uint8_t *u_data,
    size_t u_len,
    size_t u_row_stride,
    size_t u_pixel_stride,
    const uint8_t *v_data,
    size_t v_len,
    size_t v_row_stride,
    size_t v_pixel_stride,
    int32_t rotation_degrees
);
void bhe_runtime_free_session(RuntimeSession *session);
char *bhe_runtime_finish_session(RuntimeSession *session);
void bhe_runtime_free_string(char *value);
