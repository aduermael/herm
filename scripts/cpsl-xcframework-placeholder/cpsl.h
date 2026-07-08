#ifndef CPSL_H
#define CPSL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CPSL_ABI_VERSION 2

typedef struct cpsl_session cpsl_session_t;

typedef char *(*cpsl_webbrowser_handle_json_fn)(void *user_data, const char *request_json);
typedef void (*cpsl_webbrowser_string_free_fn)(char *value);
typedef void (*cpsl_webbrowser_user_data_free_fn)(void *user_data);
typedef char *(*cpsl_location_handle_json_fn)(void *user_data, const char *request_json);
typedef void (*cpsl_location_string_free_fn)(char *value);
typedef void (*cpsl_location_user_data_free_fn)(void *user_data);
typedef void (*cpsl_file_activity_handle_fn)(void *user_data, const char *path, const char *operation);
typedef void (*cpsl_file_activity_user_data_free_fn)(void *user_data);

typedef struct cpsl_webbrowser_callbacks {
    void *user_data;
    cpsl_webbrowser_handle_json_fn handle_json;
    cpsl_webbrowser_string_free_fn string_free;
    cpsl_webbrowser_user_data_free_fn user_data_free;
} cpsl_webbrowser_callbacks_t;

typedef struct cpsl_file_activity_callbacks {
    void *user_data;
    cpsl_file_activity_handle_fn handle_activity;
    cpsl_file_activity_user_data_free_fn user_data_free;
} cpsl_file_activity_callbacks_t;

typedef struct cpsl_location_callbacks {
    void *user_data;
    cpsl_location_handle_json_fn handle_json;
    cpsl_location_string_free_fn string_free;
    cpsl_location_user_data_free_fn user_data_free;
} cpsl_location_callbacks_t;

uint32_t cpsl_abi_version(void);
char *cpsl_backend_metadata_json(void);
cpsl_session_t *cpsl_session_new(const char *config_json);
/*
 * Callback invocations are synchronous, serialized per session, and may happen
 * on a non-main CPSL evaluation thread. Host callbacks that need UI work should
 * marshal to the UI thread before returning. callbacks->user_data_free, when
 * non-NULL, is called when the CPSL session releases the callback context.
 */
cpsl_session_t *cpsl_session_new_with_webbrowser_callbacks(
    const char *config_json,
    const cpsl_webbrowser_callbacks_t *callbacks
);
cpsl_session_t *cpsl_session_new_with_callbacks(
    const char *config_json,
    const cpsl_webbrowser_callbacks_t *webbrowser_callbacks,
    const cpsl_file_activity_callbacks_t *file_activity_callbacks
);
cpsl_session_t *cpsl_session_new_with_host_callbacks(
    const char *config_json,
    const cpsl_webbrowser_callbacks_t *webbrowser_callbacks,
    const cpsl_file_activity_callbacks_t *file_activity_callbacks,
    const cpsl_location_callbacks_t *location_callbacks
);
void cpsl_session_free(cpsl_session_t *session);
char *cpsl_eval(cpsl_session_t *session, const char *request_json);
void cpsl_string_free(char *value);
const char *cpsl_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* CPSL_H */
