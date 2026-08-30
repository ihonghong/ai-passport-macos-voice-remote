#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "bsp_button.h"
#include "esp_err.h"

// Build the direct-launch shortcut test UI and start its serial worker.
esp_err_t shortcut_app_start(bool battery_available, bool audio_available);

// Button-component callback. It only queues events; serial and UI work run elsewhere.
void shortcut_app_button(bsp_btn_t btn, bsp_btn_ev_t ev, void *user);

// BLE HID connection callback. It queues the state change for the UI worker.
void shortcut_app_ble_connected(bool connected, void *user);

// BLE pairing callback. A non-zero passkey is shown until the BLE layer sends
// zero after encryption completes or the connection closes.
void shortcut_app_ble_pairing(uint32_t passkey, void *user);

// Vendor HID host-status callback. It marks the wireless audio bridge ready
// and synchronizes the status-bar date and clock without a USB cable.
void shortcut_app_ble_host_status(bool audio_ready, uint8_t hour,
                                  uint8_t minute, uint16_t year,
                                  uint8_t month, uint8_t day,
                                  uint8_t weekday,
                                  uint8_t codex_remaining,
                                  uint32_t daily_tokens, void *user);
