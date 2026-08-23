#ifndef BHE_RUNTIME_H
#define BHE_RUNTIME_H

#include <stdbool.h>
#include <stdint.h>

typedef struct RuntimeSession RuntimeSession;

bool bhe_runtime_initialize_onnx(const char *library_path);
RuntimeSession *bhe_runtime_create_session(const char *config);
char *bhe_runtime_push_frame(RuntimeSession *session, const char *frame);
void bhe_runtime_free_session(RuntimeSession *session);
char *bhe_runtime_analyze_json(const char *input);
char *bhe_runtime_version(void);
void bhe_runtime_free_string(char *value);

#endif
