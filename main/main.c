// Direct-launch Mac shortcut remote for FoloToy AI Passport.
#include "bsp_battery.h"
#include "bsp_audio.h"
#include "bsp_button.h"
#include "bsp_display.h"
#include "bsp_i2c.h"
#include "bsp_pins.h"
#include "ble_keyboard.h"
#include "shortcut_app.h"

#include "esp_log.h"
#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"

#include <stdbool.h>
#include <stdio.h>

static const char *TAG = "main";

void app_main(void)
{
    usb_serial_jtag_driver_config_t usb_serial_config = {
        .tx_buffer_size = 8192,
        .rx_buffer_size = 1024,
    };
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&usb_serial_config));
    usb_serial_jtag_vfs_use_driver();

    // PCM uses every possible byte value; CRLF translation would corrupt the
    // binary USB audio frames whenever a sample contains 0x0A.
    usb_serial_jtag_vfs_set_tx_line_endings(ESP_LINE_ENDINGS_LF);
    usb_serial_jtag_vfs_set_rx_line_endings(ESP_LINE_ENDINGS_LF);
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stdin, NULL, _IONBF, 0);
    ESP_LOGI(TAG, "Starting AI Passport Mac shortcut test");

    bsp_i2c_init();
    bsp_i2c_scan();
    if (bsp_display_init() != ESP_OK || !bsp_lvgl_init()) {
        ESP_LOGE(TAG, "Display/LVGL init failed (MOSI=%d SCLK=%d CS=%d DC=%d BL=%d)",
                 BSP_LCD_MOSI, BSP_LCD_SCLK, BSP_LCD_CS, BSP_LCD_DC, BSP_LCD_BL);
        return;
    }
    // The shortcut UI manages active/idle brightness after startup.
    bsp_display_backlight(70);

    bool battery_available = (bsp_battery_init() == ESP_OK);
    bool audio_available = (bsp_audio_init() == ESP_OK &&
                            bsp_audio_set_format(16000, 16, 1) == ESP_OK);
    esp_err_t app_result = shortcut_app_start(battery_available, audio_available);
    if (app_result != ESP_OK) {
        ESP_LOGE(TAG, "Shortcut UI/task init failed: %s", esp_err_to_name(app_result));
        return;
    }

    esp_err_t ble_result = ble_keyboard_start(shortcut_app_ble_connected,
                                              shortcut_app_ble_pairing,
                                              shortcut_app_ble_host_status,
                                              NULL);
    if (ble_result != ESP_OK) {
        ESP_LOGE(TAG, "BLE keyboard init failed: %s", esp_err_to_name(ble_result));
        return;
    }

    esp_err_t button_result = bsp_button_init(shortcut_app_button, NULL);
    if (button_result != ESP_OK) {
        ESP_LOGE(TAG, "Button init failed: %s", esp_err_to_name(button_result));
        return;
    }

    ESP_LOGI(TAG, "Ready: buttons=%d battery=%d audio=%d ble_keyboard=%d", 1,
             battery_available, audio_available, 1);
}
