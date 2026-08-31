#include "shortcut_keymap.h"

#include <string.h>

static uint8_t shortcut_keymap_checksum(const uint8_t *data, size_t length)
{
    // CRC-8/ATM catches truncated or partially overwritten HID/NVS records.
    uint8_t crc = 0;
    for (size_t i = 0; i < length; ++i) {
        crc ^= data[i];
        for (unsigned bit = 0; bit < 8; ++bit) {
            crc = (crc & 0x80U) ? (uint8_t)((crc << 1U) ^ 0x07U)
                                : (uint8_t)(crc << 1U);
        }
    }
    return crc;
}

shortcut_keymap_t shortcut_keymap_default(void)
{
    return (shortcut_keymap_t){
        .button = {
            [SHORTCUT_BUTTON_DOWN] = {
                .modifiers = SHORTCUT_HID_MOD_LEFT_CTRL |
                             SHORTCUT_HID_MOD_LEFT_GUI,
                .key_code = 0,
            },
            [SHORTCUT_BUTTON_OK] = {
                .modifiers = 0,
                .key_code = SHORTCUT_HID_KEY_RETURN,
            },
            [SHORTCUT_BUTTON_UP] = {
                .modifiers = SHORTCUT_HID_MOD_LEFT_GUI,
                .key_code = SHORTCUT_HID_KEY_DELETE,
            },
        },
    };
}

bool shortcut_keymap_valid(const shortcut_keymap_t *keymap)
{
    if (!keymap) return false;
    for (size_t i = 0; i < SHORTCUT_BUTTON_COUNT; ++i) {
        const shortcut_chord_t chord = keymap->button[i];
        if (chord.key_code > SHORTCUT_HID_KEY_MAX) return false;
        if (chord.modifiers == 0 && chord.key_code == 0) return false;
    }
    return true;
}

bool shortcut_keymap_encode(const shortcut_keymap_t *keymap,
                            uint8_t output[SHORTCUT_KEYMAP_WIRE_BYTES])
{
    if (!output || !shortcut_keymap_valid(keymap)) return false;
    output[0] = SHORTCUT_KEYMAP_WIRE_MARKER;
    for (size_t i = 0; i < SHORTCUT_BUTTON_COUNT; ++i) {
        output[1 + i * 2] = keymap->button[i].modifiers;
        output[2 + i * 2] = keymap->button[i].key_code;
    }
    output[7] = shortcut_keymap_checksum(output, 7);
    return true;
}

bool shortcut_keymap_decode(const uint8_t *data, size_t length,
                            shortcut_keymap_t *keymap)
{
    if (!data || !keymap || length != SHORTCUT_KEYMAP_WIRE_BYTES ||
        data[0] != SHORTCUT_KEYMAP_WIRE_MARKER ||
        data[7] != shortcut_keymap_checksum(data, 7)) {
        return false;
    }

    shortcut_keymap_t decoded = {0};
    for (size_t i = 0; i < SHORTCUT_BUTTON_COUNT; ++i) {
        decoded.button[i].modifiers = data[1 + i * 2];
        decoded.button[i].key_code = data[2 + i * 2];
    }
    if (!shortcut_keymap_valid(&decoded)) return false;
    memcpy(keymap, &decoded, sizeof(decoded));
    return true;
}
