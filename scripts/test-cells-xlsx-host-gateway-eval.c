/*
 * Product-path proof: rebuilt libcpsl.dylib host_callbacks_v4 + real cells_xlsx.
 * Mirrors the Swift CPSLExcelService JSON protocol used by the Apple app.
 */
#include "cells_xlsx.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct cpsl_session cpsl_session_t;

typedef char *(*xlsx_handle_json_fn)(void *user_data, const char *request_json);
typedef void (*xlsx_string_free_fn)(char *value);
typedef void (*xlsx_user_data_free_fn)(void *user_data);

typedef struct cpsl_xlsx_callbacks {
    void *user_data;
    xlsx_handle_json_fn handle_json;
    xlsx_string_free_fn string_free;
    xlsx_user_data_free_fn user_data_free;
} cpsl_xlsx_callbacks_t;

typedef cpsl_session_t *(*session_new_v4_fn)(
    const char *config_json,
    const void *webbrowser_callbacks,
    const void *file_activity_callbacks,
    const void *calendar_activity_callbacks,
    const void *location_callbacks,
    const void *vision_callbacks,
    const cpsl_xlsx_callbacks_t *xlsx_callbacks);
typedef void (*session_free_fn)(cpsl_session_t *session);
typedef char *(*eval_fn)(cpsl_session_t *session, const char *request_json);
typedef void (*string_free_fn)(char *value);
typedef const char *(*last_error_fn)(void);

typedef struct {
    CellsXlsxWorkbook *books[64];
    char ids[64][32];
    int count;
    int next_id;
} HostState;

static char *owned_strdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = (char *)malloc(n);
    if (p) {
        memcpy(p, s, n);
    }
    return p;
}

static char *json_ok_workbook(const char *id) {
    char buf[256];
    snprintf(buf, sizeof(buf), "{\"ok\":true,\"workbook\":\"%s\"}", id);
    return owned_strdup(buf);
}

static char *json_ok_empty(void) { return owned_strdup("{\"ok\":true}"); }

static char *json_ok_value_string(const char *v) {
    /* escape is unnecessary for our fixed test values */
    char buf[512];
    snprintf(buf, sizeof(buf), "{\"ok\":true,\"value\":\"%s\"}", v);
    return owned_strdup(buf);
}

static char *json_ok_value_number(double n) {
    char buf[256];
    snprintf(buf, sizeof(buf), "{\"ok\":true,\"value\":%.17g}", n);
    return owned_strdup(buf);
}

static char *json_err(const char *msg) {
    char buf[512];
    snprintf(buf, sizeof(buf), "{\"ok\":false,\"error\":\"%s\"}", msg);
    return owned_strdup(buf);
}

static const char *json_get_string(const char *json, const char *key, char *out, size_t out_sz) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\":\"", key);
    const char *p = strstr(json, pattern);
    if (!p) {
        return NULL;
    }
    p += strlen(pattern);
    size_t i = 0;
    while (*p && *p != '"' && i + 1 < out_sz) {
        out[i++] = *p++;
    }
    out[i] = '\0';
    return out;
}

static int json_get_int(const char *json, const char *key, int *out) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char *p = strstr(json, pattern);
    if (!p) {
        return -1;
    }
    p += strlen(pattern);
    *out = (int)strtol(p, NULL, 10);
    return 0;
}

static double json_get_double(const char *json, const char *key, int *ok) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char *p = strstr(json, pattern);
    if (!p) {
        *ok = 0;
        return 0;
    }
    p += strlen(pattern);
    *ok = 1;
    return strtod(p, NULL);
}

static CellsXlsxWorkbook *lookup(HostState *st, const char *id) {
    for (int i = 0; i < st->count; i++) {
        if (strcmp(st->ids[i], id) == 0) {
            return st->books[i];
        }
    }
    return NULL;
}

static char *store(HostState *st, CellsXlsxWorkbook *wb) {
    if (st->count >= 64) {
        return json_err("too many workbooks");
    }
    char id[32];
    snprintf(id, sizeof(id), "wb%d", st->next_id++);
    strcpy(st->ids[st->count], id);
    st->books[st->count] = wb;
    st->count++;
    return json_ok_workbook(id);
}

static char *host_handle_json(void *user_data, const char *request_json) {
    HostState *st = (HostState *)user_data;
    if (!request_json) {
        return json_err("null request");
    }

    char command[64] = {0};
    if (!json_get_string(request_json, "command", command, sizeof(command))) {
        return json_err("missing command");
    }

    if (strcmp(command, "create") == 0) {
        CellsXlsxWorkbook *wb = cells_xlsx_create();
        if (!wb) {
            return json_err(cells_xlsx_last_error());
        }
        return store(st, wb);
    }

    if (strcmp(command, "open") == 0) {
        char path[1024] = {0};
        if (!json_get_string(request_json, "path", path, sizeof(path))) {
            return json_err("open: missing path");
        }
        CellsXlsxWorkbook *wb = cells_xlsx_open(path);
        if (!wb) {
            return json_err(cells_xlsx_last_error());
        }
        return store(st, wb);
    }

    if (strcmp(command, "close") == 0) {
        char id[64] = {0};
        if (!json_get_string(request_json, "workbook", id, sizeof(id))) {
            return json_err("missing workbook");
        }
        for (int i = 0; i < st->count; i++) {
            if (strcmp(st->ids[i], id) == 0) {
                cells_xlsx_close(st->books[i]);
                int last = st->count - 1;
                if (i != last) {
                    st->books[i] = st->books[last];
                    memcpy(st->ids[i], st->ids[last], sizeof(st->ids[i]));
                }
                st->books[last] = NULL;
                st->ids[last][0] = '\0';
                st->count--;
                break;
            }
        }
        return json_ok_empty();
    }

    char id[64] = {0};
    if (!json_get_string(request_json, "workbook", id, sizeof(id))) {
        return json_err("missing workbook");
    }
    CellsXlsxWorkbook *wb = lookup(st, id);
    if (!wb) {
        return json_err("invalid workbook");
    }

    if (strcmp(command, "set_string") == 0) {
        int sheet = 0, col = 0, row = 0;
        json_get_int(request_json, "sheet", &sheet);
        json_get_int(request_json, "col", &col);
        json_get_int(request_json, "row", &row);
        char value[512] = {0};
        if (!json_get_string(request_json, "value", value, sizeof(value))) {
            return json_err("set_string: missing value");
        }
        if (cells_xlsx_set_string(wb, sheet, col, row, value) != 0) {
            return json_err(cells_xlsx_last_error());
        }
        return json_ok_empty();
    }

    if (strcmp(command, "set_number") == 0) {
        int sheet = 0, col = 0, row = 0, ok = 0;
        json_get_int(request_json, "sheet", &sheet);
        json_get_int(request_json, "col", &col);
        json_get_int(request_json, "row", &row);
        double value = json_get_double(request_json, "value", &ok);
        if (!ok) {
            return json_err("set_number: missing value");
        }
        if (cells_xlsx_set_number(wb, sheet, col, row, value) != 0) {
            return json_err(cells_xlsx_last_error());
        }
        return json_ok_empty();
    }

    if (strcmp(command, "write") == 0) {
        char path[1024] = {0};
        if (!json_get_string(request_json, "path", path, sizeof(path))) {
            return json_err("write: missing path");
        }
        if (cells_xlsx_write(wb, path) != 0) {
            return json_err(cells_xlsx_last_error());
        }
        return json_ok_empty();
    }

    if (strcmp(command, "get_string") == 0) {
        int sheet = 0, col = 0, row = 0;
        json_get_int(request_json, "sheet", &sheet);
        json_get_int(request_json, "col", &col);
        json_get_int(request_json, "row", &row);
        const char *s = cells_xlsx_get_string(wb, sheet, col, row);
        if (!s) {
            return json_err(cells_xlsx_last_error());
        }
        return json_ok_value_string(s);
    }

    if (strcmp(command, "get_number") == 0) {
        int sheet = 0, col = 0, row = 0;
        json_get_int(request_json, "sheet", &sheet);
        json_get_int(request_json, "col", &col);
        json_get_int(request_json, "row", &row);
        double n = cells_xlsx_get_number(wb, sheet, col, row);
        return json_ok_value_number(n);
    }

    return json_err("unsupported command");
}

static void host_string_free(char *value) { free(value); }

static void host_user_data_free(void *user_data) {
    HostState *st = (HostState *)user_data;
    if (!st) {
        return;
    }
    for (int i = 0; i < st->count; i++) {
        cells_xlsx_close(st->books[i]);
    }
    free(st);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <libcpsl.dylib> <workdir>\n", argv[0]);
        return 2;
    }
    const char *dylib_path = argv[1];
    const char *workdir = argv[2];

    void *lib = dlopen(dylib_path, RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 1;
    }

    session_new_v4_fn session_new_v4 =
        (session_new_v4_fn)dlsym(lib, "cpsl_session_new_with_host_callbacks_v4");
    session_free_fn session_free = (session_free_fn)dlsym(lib, "cpsl_session_free");
    eval_fn eval = (eval_fn)dlsym(lib, "cpsl_eval");
    string_free_fn string_free = (string_free_fn)dlsym(lib, "cpsl_string_free");
    last_error_fn last_error = (last_error_fn)dlsym(lib, "cpsl_last_error");

    if (!session_new_v4 || !session_free || !eval || !string_free) {
        fprintf(stderr, "missing CPSL symbols (v4=%p eval=%p)\n", (void *)session_new_v4,
                (void *)eval);
        return 1;
    }
    printf("SYMBOL_OK cpsl_session_new_with_host_callbacks_v4\n");

    HostState *st = (HostState *)calloc(1, sizeof(HostState));
    st->next_id = 1;
    cpsl_xlsx_callbacks_t xlsx_cb = {
        .user_data = st,
        .handle_json = host_handle_json,
        .string_free = host_string_free,
        .user_data_free = host_user_data_free,
    };

    char config[2048];
    snprintf(config, sizeof(config),
             "{"
             "\"language\":\"luau\","
             "\"initial_cwd\":\"/workdir\","
             "\"mounts\":[{\"host\":\"%s\",\"virtual\":\"/workdir\",\"mode\":\"rw\"}],"
             "\"http\":{\"mode\":\"policy\",\"allow_domains\":[],\"deny_domains\":[]}"
             "}",
             workdir);

    cpsl_session_t *session =
        session_new_v4(config, NULL, NULL, NULL, NULL, NULL, &xlsx_cb);
    if (!session) {
        fprintf(stderr, "session_new_v4 failed: %s\n",
                last_error ? last_error() : "(no last_error)");
        return 1;
    }
    printf("SESSION_OK\n");

    const char *script =
        "local created = xlsx.create()\n"
        "local wb = created.workbook\n"
        "xlsx.set_string(wb, 0, 0, 0, \"hello\")\n"
        "xlsx.set_number(wb, 0, 1, 0, 42.5)\n"
        "xlsx.write(wb, \"/workdir/out.xlsx\")\n"
        "xlsx.close(wb)\n"
        "local reopened = xlsx.open(\"/workdir/out.xlsx\")\n"
        "local wb2 = reopened.workbook\n"
        "local s = xlsx.get_string(wb2, 0, 0, 0).value\n"
        "local n = xlsx.get_number(wb2, 0, 1, 0).value\n"
        "xlsx.close(wb2)\n"
        "return s .. \"|\" .. tostring(n)\n";

    char request[4096];
    /* Escape newlines into JSON string */
    {
        char escaped[3500];
        size_t j = 0;
        for (size_t i = 0; script[i] && j + 2 < sizeof(escaped); i++) {
            char c = script[i];
            if (c == '\\' || c == '"') {
                escaped[j++] = '\\';
                escaped[j++] = c;
            } else if (c == '\n') {
                escaped[j++] = '\\';
                escaped[j++] = 'n';
            } else if (c == '\r') {
                /* skip */
            } else {
                escaped[j++] = c;
            }
        }
        escaped[j] = '\0';
        snprintf(request, sizeof(request),
                 "{\"language\":\"luau\",\"input\":\"%s\",\"timeout_ms\":60000}", escaped);
    }

    char *response = eval(session, request);
    if (!response) {
        fprintf(stderr, "eval failed: %s\n", last_error ? last_error() : "(no last_error)");
        session_free(session);
        return 1;
    }
    printf("EVAL_RAW=%s\n", response);

    /* Prefer result field if present */
    char result_buf[256] = {0};
    if (json_get_string(response, "result", result_buf, sizeof(result_buf)) ||
        json_get_string(response, "value", result_buf, sizeof(result_buf)) ||
        strstr(response, "hello|42.5")) {
        if (strstr(response, "hello|42.5")) {
            printf("RESULT=hello|42.5\n");
        } else {
            printf("RESULT=%s\n", result_buf);
        }
    } else {
        fprintf(stderr, "unexpected eval response (no hello|42.5): %s\n", response);
        string_free(response);
        session_free(session);
        return 1;
    }

    if (!strstr(response, "hello|42.5") && !strstr(result_buf, "hello|42.5")) {
        fprintf(stderr, "RESULT mismatch\n");
        string_free(response);
        session_free(session);
        return 1;
    }

    string_free(response);
    session_free(session);
    printf("PASS product host_callbacks_v4 + cells_xlsx Luau round-trip\n");
    return 0;
}
