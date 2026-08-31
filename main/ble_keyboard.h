#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "shortcut_keymap.h"

typedef void (*ble_keyboard_connection_cb_t)(bool connected, void *user);
typedef void (*ble_keyboard_pairing_cb_t)(uint32_t passkey, void *user);
typedef void (*ble_keyboard_host_status_cb_t)(bool audio_ready, uint8_t hour,
                                              uint8_t minute, uint16_t year,
                                              uint8_t month, uint8_t day,
                                              uint8_t weekday,
                                              uint8_t codex_remaining,
                                              uint32_t daily_tokens,
                                              void *user);

// Start a bondable BLE HID keyboard named "AI Passport". In addition to the
// standard keyboard collection, the HID map exposes a vendor collection used
// for microphone packets and host time/status updates.
esp_err_t ble_keyboard_start(ble_keyboard_connection_cb_t connection_callback,
                             ble_keyboard_pairing_cb_t pairing_callback,
                             ble_keyboard_host_status_cb_t host_status_callback,
                             void *user);

bool ble_keyboard_connected(void);

// Ask macOS for an idle or streaming connection profile. Rejection is
// non-fatal: the existing connection remains usable with its negotiated
// parameters. The idle profile keeps keyboard latency bounded by one base
// interval while allowing the peripheral to skip empty connection events.
void ble_keyboard_set_streaming(bool streaming);

// Restore fast advertising for a short window after local user activity.
// This is a no-op while connected; disconnected idle advertising otherwise
// backs off to reduce radio wakeups when the Mac is absent.
void ble_keyboard_promote_advertising(void);

// Poll the locally stored host Output Report. ESP-IDF's NimBLE HID backend
// accepts this report but does not emit ESP_HIDD_OUTPUT_EVENT for it.
void ble_keyboard_poll_host_status(void);

// Send one standard 8-byte keyboard report. key_code may be zero for a
// modifier-only shortcut such as left Control + left GUI/Command.
esp_err_t ble_keyboard_report(uint8_t modifiers, uint8_t key_code);

// Press and release one non-modifier key.
esp_err_t ble_keyboard_tap(uint8_t key_code);

// Press and release one key with modifiers.
esp_err_t ble_keyboard_tap_chord(uint8_t modifiers, uint8_t key_code);

// Send the configured chord for a semantic action. The map is loaded from NVS
// at startup and can be replaced atomically through host Output Report 3.
esp_err_t ble_keyboard_shortcut_press(shortcut_action_t action);
esp_err_t ble_keyboard_shortcut_release(shortcut_action_t action);
esp_err_t ble_keyboard_shortcut_tap(shortcut_action_t action);

// Stream 8 kHz signed 8-bit mono PCM through the vendor BLE HID input report.
// The Mac bridge expands it back to 16-bit before feeding Core Audio.
esp_err_t ble_keyboard_audio_start(uint16_t sample_rate);
esp_err_t ble_keyboard_audio_write(const int8_t *pcm, size_t samples);
esp_err_t ble_keyboard_audio_stop(void);

// USB HID keyboard values used by the shortcut app.
#define BLE_KBD_MOD_LEFT_CTRL SHORTCUT_HID_MOD_LEFT_CTRL
#define BLE_KBD_MOD_LEFT_GUI  SHORTCUT_HID_MOD_LEFT_GUI
#define BLE_KBD_KEY_RETURN    SHORTCUT_HID_KEY_RETURN
#define BLE_KBD_KEY_ESCAPE    SHORTCUT_HID_KEY_ESCAPE
#define BLE_KBD_KEY_DELETE    SHORTCUT_HID_KEY_DELETE
