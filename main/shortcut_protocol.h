#pragma once

#include <stdbool.h>

typedef enum {
    SHORTCUT_HOST_NONE = 0,
    SHORTCUT_HOST_HELLO,
    SHORTCUT_HOST_TIME,
} shortcut_host_message_type_t;

typedef struct {
    shortcut_host_message_type_t type;
    char time_text[6];
} shortcut_host_message_t;

// Parse one newline-delimited host message. TIME accepts only a valid HH:MM.
bool shortcut_protocol_parse(const char *line, shortcut_host_message_t *message);
