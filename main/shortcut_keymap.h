#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define SHORTCUT_KEYMAP_WIRE_BYTES 8
#define SHORTCUT_KEYMAP_WIRE_MARKER 'K'

// Standard keyboard usages supported by the existing BLE report descriptor.
#define SHORTCUT_HID_MOD_LEFT_CTRL 0x01
#define SHORTCUT_HID_MOD_LEFT_GUI  0x08
#define SHORTCUT_HID_KEY_RETURN    0x28
#define SHORTCUT_HID_KEY_ESCAPE    0x29
#define SHORTCUT_HID_KEY_DELETE    0x2A
#define SHORTCUT_HID_KEY_MAX       0x65

typedef enum {
    SHORTCUT_ACTION_VOICE = 0,
    SHORTCUT_ACTION_SEND,
    SHORTCUT_ACTION_CLEAR,
    SHORTCUT_ACTION_COUNT,
} shortcut_action_t;

typedef struct {
    uint8_t modifiers;
    uint8_t key_code;
} shortcut_chord_t;

typedef struct {
    shortcut_chord_t action[SHORTCUT_ACTION_COUNT];
} shortcut_keymap_t;

// Return the public defaults used when no valid user configuration exists.
shortcut_keymap_t shortcut_keymap_default(void);

// Reject empty actions and reserved modifier bits before persisting a map.
bool shortcut_keymap_valid(const shortcut_keymap_t *keymap);

// Encode/decode the complete map as one atomic eight-byte HID/NVS record.
bool shortcut_keymap_encode(const shortcut_keymap_t *keymap,
                            uint8_t output[SHORTCUT_KEYMAP_WIRE_BYTES]);
bool shortcut_keymap_decode(const uint8_t *data, size_t length,
                            shortcut_keymap_t *keymap);
