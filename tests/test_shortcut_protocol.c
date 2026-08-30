#include "shortcut_protocol.h"

#include <assert.h>
#include <string.h>

int main(void)
{
    shortcut_host_message_t message;

    assert(shortcut_protocol_parse("HOST:HELLO", &message));
    assert(message.type == SHORTCUT_HOST_HELLO);

    assert(shortcut_protocol_parse("HOST:TIME,09:07", &message));
    assert(message.type == SHORTCUT_HOST_TIME);
    assert(strcmp(message.time_text, "09:07") == 0);

    assert(!shortcut_protocol_parse("HOST:TIME,24:00", &message));
    assert(!shortcut_protocol_parse("HOST:TIME,09:60", &message));
    assert(!shortcut_protocol_parse("HOST:TIME,9:07", &message));
    assert(!shortcut_protocol_parse("HOST:UNKNOWN", &message));
    assert(!shortcut_protocol_parse(NULL, &message));
    assert(!shortcut_protocol_parse("HOST:HELLO", NULL));
    return 0;
}
