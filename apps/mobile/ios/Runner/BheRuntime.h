#import <stdbool.h>

typedef struct RuntimeSession RuntimeSession;

RuntimeSession *bhe_runtime_create_session(const char *config);
char *bhe_runtime_push_frame(RuntimeSession *session, const char *frame);
void bhe_runtime_free_session(RuntimeSession *session);
void bhe_runtime_free_string(char *value);
