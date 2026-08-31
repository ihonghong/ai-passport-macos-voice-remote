#include "shortcut_keymap.h"

#include <assert.h>
#include <string.h>

int main(void)
{
    shortcut_keymap_t defaults = shortcut_keymap_default();
    assert(shortcut_keymap_valid(&defaults));
    assert(defaults.button[SHORTCUT_BUTTON_DOWN].modifiers ==
           (SHORTCUT_HID_MOD_LEFT_CTRL | SHORTCUT_HID_MOD_LEFT_GUI));
    assert(defaults.button[SHORTCUT_BUTTON_DOWN].key_code == 0);
    assert(defaults.button[SHORTCUT_BUTTON_MID].key_code ==
           SHORTCUT_HID_KEY_RETURN);

    uint8_t encoded[SHORTCUT_KEYMAP_WIRE_BYTES];
    assert(shortcut_keymap_encode(&defaults, encoded));
    shortcut_keymap_t decoded;
    assert(shortcut_keymap_decode(encoded, sizeof(encoded), &decoded));
    assert(memcmp(&defaults, &decoded, sizeof(defaults)) == 0);

    encoded[3] ^= 1;
    assert(!shortcut_keymap_decode(encoded, sizeof(encoded), &decoded));
    assert(!shortcut_keymap_decode(encoded, sizeof(encoded) - 1, &decoded));

    shortcut_keymap_t empty = defaults;
    empty.button[SHORTCUT_BUTTON_MID] = (shortcut_chord_t){0};
    assert(!shortcut_keymap_valid(&empty));
    assert(!shortcut_keymap_encode(&empty, encoded));
    return 0;
}
