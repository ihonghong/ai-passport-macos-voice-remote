#include "shortcut_protocol.h"

#include <ctype.h>
#include <stdio.h>
#include <string.h>

bool shortcut_protocol_parse(const char *line, shortcut_host_message_t *message)
{
    if (!line || !message) return false;

    memset(message, 0, sizeof(*message));
    if (strcmp(line, "HOST:HELLO") == 0) {
        message->type = SHORTCUT_HOST_HELLO;
        return true;
    }

    const char *prefix = "HOST:TIME,";
    if (strncmp(line, prefix, strlen(prefix)) != 0) return false;

    const char *value = line + strlen(prefix);
    if (strlen(value) != 5 || value[2] != ':' ||
        !isdigit((unsigned char)value[0]) || !isdigit((unsigned char)value[1]) ||
        !isdigit((unsigned char)value[3]) || !isdigit((unsigned char)value[4])) {
        return false;
    }

    int hour = (value[0] - '0') * 10 + (value[1] - '0');
    int minute = (value[3] - '0') * 10 + (value[4] - '0');
    if (hour > 23 || minute > 59) return false;

    message->type = SHORTCUT_HOST_TIME;
    snprintf(message->time_text, sizeof(message->time_text), "%s", value);
    return true;
}
