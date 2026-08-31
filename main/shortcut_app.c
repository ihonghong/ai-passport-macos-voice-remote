#include "shortcut_app.h"

#include "ble_keyboard.h"
#include "bsp_audio.h"
#include "bsp_battery.h"
#include "bsp_display.h"
#include "pet_plugin.h"
#include "provider_profile.h"
#include "shortcut_protocol.h"
#include "ui_pixel.h"

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "driver/usb_serial_jtag.h"
#include "esp_log.h"
#include "lvgl.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef enum {
    UI_WAITING = 0,
    UI_READY,
    UI_LISTENING,
    UI_RETURN_SENT,
    UI_CLEARED,
} shortcut_ui_state_t;

typedef enum {
    SHORTCUT_EVENT_BUTTON = 0,
    SHORTCUT_EVENT_BLE_STATUS,
    SHORTCUT_EVENT_BLE_PAIRING,
    SHORTCUT_EVENT_BLE_HOST_STATUS,
} shortcut_event_kind_t;

typedef struct {
    shortcut_event_kind_t kind;
    bool ble_connected;
    uint32_t pairing_passkey;
    bool audio_ready;
    uint8_t hour;
    uint8_t minute;
    uint16_t year;
    uint8_t month;
    uint8_t day;
    uint8_t weekday;
    uint8_t codex_remaining;
    uint32_t daily_tokens;
    bsp_btn_t btn;
    bsp_btn_ev_t ev;
} shortcut_button_event_t;

static QueueHandle_t s_button_queue;
static QueueHandle_t s_status_queue;
static SemaphoreHandle_t s_serial_mutex;
static TaskHandle_t s_audio_task;
static TaskHandle_t s_shortcut_task;
static bool s_battery_available;
static bool s_audio_available;
static bool s_mac_connected;
static volatile bool s_audio_host_ready;
static bool s_voice_held;
static volatile bool s_audio_requested;
static volatile bool s_voice_button_down;
static volatile uint32_t s_voice_transition_count;
static int s_battery_soc = -1;
static int s_codex_remaining = -1;
static int32_t s_daily_tokens = -1;
static int s_weekday = -1;
static char s_time_text[6] = "--:--";
static char s_date_text[12] = "----.--.--";
static shortcut_ui_state_t s_ui_state = UI_WAITING;
static uint32_t s_pairing_passkey;

static lv_obj_t *s_screen;
static lv_obj_t *s_time_label;
static lv_obj_t *s_date_label;
static lv_obj_t *s_battery_label;
static lv_obj_t *s_battery_fill;
static lv_obj_t *s_state_label;
static lv_obj_t *s_codex_label;
static lv_obj_t *s_daily_tokens_label;
static lv_obj_t *s_codex_bar;
static lv_obj_t *s_daily_tokens_bar;
static lv_obj_t *s_state_dot;
static lv_obj_t *s_pairing_group;
static lv_obj_t *s_pairing_code_label;
static lv_obj_t *s_pet_image;
static const shortcut_pet_plugin_t *s_pet_plugin;
static lv_obj_t *s_wave_group;
static lv_obj_t *s_wave_bars[8];
static lv_obj_t *s_listening_group;
static lv_obj_t *s_listening_dot;
static lv_obj_t *s_listening_timer_label;
static lv_timer_t *s_animation_timer;
static bool s_animation_paused;
static TickType_t s_listening_started_at;

#define AUDIO_SAMPLE_RATE 16000
#define AUDIO_FRAME_SAMPLES 320
#define BACKLIGHT_ACTIVE_PERCENT 70
#define BACKLIGHT_IDLE_PERCENT 15
#define BACKLIGHT_LOW_PERCENT 5
#define BACKLIGHT_ACTIVE_MS 10000
#define BACKLIGHT_DEEP_IDLE_MS 60000
#define BATTERY_LOW_PERCENT 10
#define BATTERY_CRITICAL_PERCENT 5
#define UI_DASH_BG 0x09131E
#define UI_DASH_SURFACE 0x142636
#define UI_DASH_TEXT 0xF2F7F8
#define UI_DASH_MUTED 0x7893A6
#define UI_DASH_ACCENT 0x56E0C2
#define UI_DASH_TOKEN 0x63A9FF
#define UI_DASH_WARN 0xF3BD55
#define UI_DASH_ACTIVE 0xFF7657
#define UI_DASH_ACTIVE_MUTED 0xB85242

#define UI_ANIMATION_MS 140
#define WAVE_BAR_COUNT 8

// Physical roles live here so ergonomic remapping does not touch behavior.
#define BUTTON_VOICE BSP_BTN_DOWN
#define BUTTON_SEND BSP_BTN_OK
#define BUTTON_CLEAR BSP_BTN_UP

static TickType_t s_backlight_active_until;
static TickType_t s_backlight_deep_idle_at;
static uint8_t s_backlight_percent = 0xff;
static bool s_deep_idle;

static lv_obj_t *ui_dash_block(lv_obj_t *parent, int x, int y, int w, int h,
                               uint32_t color, int radius)
{
    lv_obj_t *obj = lv_obj_create(parent);
    lv_obj_remove_flag(obj, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_pos(obj, x, y);
    lv_obj_set_size(obj, w, h);
    lv_obj_set_style_radius(obj, radius, 0);
    lv_obj_set_style_border_width(obj, 0, 0);
    lv_obj_set_style_pad_all(obj, 0, 0);
    lv_obj_set_style_bg_color(obj, lv_color_hex(color), 0);
    return obj;
}

static lv_obj_t *ui_dash_container(lv_obj_t *parent, int x, int y, int w, int h)
{
    lv_obj_t *obj = lv_obj_create(parent);
    lv_obj_remove_flag(obj, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_pos(obj, x, y);
    lv_obj_set_size(obj, w, h);
    lv_obj_set_style_bg_opa(obj, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(obj, 0, 0);
    lv_obj_set_style_pad_all(obj, 0, 0);
    return obj;
}

typedef struct __attribute__((packed)) {
    uint8_t magic[8];
    uint16_t payload_bytes;
    uint16_t sequence;
} audio_frame_header_t;

static const uint8_t s_audio_magic[8] = {
    0xA5, 'A', 'I', 'P', 'C', 'M', '1', 0x5A
};

static bool audio_transport_ready(void)
{
    // The ESP-IDF NimBLE HID backend accepts host Output Reports but does not
    // forward them as ESP_HIDD_OUTPUT_EVENT. A live BLE HID connection is
    // therefore the usable readiness signal for the wireless transport.
    return s_mac_connected || s_audio_host_ready;
}

static void set_backlight(uint8_t percent)
{
    if (percent == s_backlight_percent) return;
    s_backlight_percent = percent;
    bsp_display_backlight(percent);
}

static void set_animation_paused(bool paused)
{
    if (!s_animation_timer || s_animation_paused == paused) return;
    if (!bsp_lvgl_lock(50)) return;
    if (paused) {
        lv_timer_pause(s_animation_timer);
    } else {
        lv_timer_resume(s_animation_timer);
        lv_timer_reset(s_animation_timer);
    }
    s_animation_paused = paused;
    bsp_lvgl_unlock();
}

static void display_activity(void)
{
    TickType_t now = xTaskGetTickCount();
    s_backlight_active_until = now + pdMS_TO_TICKS(BACKLIGHT_ACTIVE_MS);
    s_backlight_deep_idle_at = now + pdMS_TO_TICKS(BACKLIGHT_DEEP_IDLE_MS);
    s_deep_idle = false;
    set_backlight(BACKLIGHT_ACTIVE_PERCENT);
}

static void update_backlight(TickType_t now)
{
    if (usb_serial_jtag_is_connected() || s_voice_held ||
        now < s_backlight_active_until) {
        s_deep_idle = false;
        set_animation_paused(false);
        set_backlight(BACKLIGHT_ACTIVE_PERCENT);
    } else if (s_battery_soc >= 0 && s_battery_soc <= BATTERY_CRITICAL_PERCENT) {
        s_deep_idle = true;
        set_animation_paused(true);
        set_backlight(0);
    } else if ((s_battery_soc >= 0 &&
                s_battery_soc <= BATTERY_LOW_PERCENT) ||
               now >= s_backlight_deep_idle_at) {
        s_deep_idle = true;
        set_animation_paused(true);
        set_backlight(BACKLIGHT_LOW_PERCENT);
    } else {
        s_deep_idle = false;
        set_animation_paused(false);
        set_backlight(BACKLIGHT_IDLE_PERCENT);
    }
}

static void ui_refresh_locked(void)
{
    static const char *const weekdays[] = {
        "MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"
    };
    static const char *const states[] = {
        "PAIR", "READY", "LISTENING", "SENT", "CLEARED"
    };

    lv_label_set_text(s_time_label, s_time_text);
    if (s_weekday >= 1 && s_weekday <= 7) {
        lv_label_set_text_fmt(s_date_label, "%s  %s", s_date_text,
                              weekdays[s_weekday - 1]);
    } else {
        lv_label_set_text(s_date_label, s_date_text);
    }
    if (s_battery_soc >= 0) {
        lv_label_set_text_fmt(s_battery_label, "%d%%", s_battery_soc);
        int fill_width = (16 * s_battery_soc + 99) / 100;
        if (fill_width < 1) fill_width = 1;
        if (fill_width > 16) fill_width = 16;
        lv_obj_set_width(s_battery_fill, fill_width);
        lv_obj_remove_flag(s_battery_fill, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_label_set_text(s_battery_label, "--%");
        lv_obj_add_flag(s_battery_fill, LV_OBJ_FLAG_HIDDEN);
    }
    if (s_codex_remaining >= 0) {
        lv_label_set_text_fmt(s_codex_label, "%d%%", s_codex_remaining);
        lv_bar_set_value(s_codex_bar, s_codex_remaining, LV_ANIM_OFF);
    } else {
        lv_label_set_text(s_codex_label, "--%");
        lv_bar_set_value(s_codex_bar, 0, LV_ANIM_OFF);
    }
    if (s_daily_tokens < 0) {
        lv_label_set_text(s_daily_tokens_label, "--");
        lv_bar_set_value(s_daily_tokens_bar, 0, LV_ANIM_OFF);
    } else if (s_daily_tokens >= 1260000000) {
        lv_label_set_text(s_daily_tokens_label, "1.2B+");
        lv_bar_set_value(s_daily_tokens_bar, 1000, LV_ANIM_OFF);
    } else if (s_daily_tokens >= 1000000000) {
        lv_label_set_text_fmt(s_daily_tokens_label, "%ld.%01ldB",
                              (long)(s_daily_tokens / 1000000000),
                              (long)((s_daily_tokens % 1000000000) / 100000000));
        lv_bar_set_value(s_daily_tokens_bar, 1000, LV_ANIM_OFF);
    } else {
        lv_label_set_text_fmt(s_daily_tokens_label, "%ldM",
                              (long)(s_daily_tokens / 1000000));
        lv_bar_set_value(s_daily_tokens_bar,
                         (int32_t)(s_daily_tokens / 1000000), LV_ANIM_OFF);
    }
    uint32_t quota_color = (s_codex_remaining >= 0 && s_codex_remaining <= 20)
                               ? UI_DASH_WARN
                               : UI_DASH_ACCENT;
    lv_obj_set_style_bg_color(s_codex_bar, lv_color_hex(quota_color),
                              LV_PART_INDICATOR);
    if (s_pairing_passkey != 0) {
        lv_label_set_text_fmt(s_pairing_code_label, "%06lu",
                              (unsigned long)s_pairing_passkey);
        lv_obj_remove_flag(s_pairing_group, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(s_pairing_group, LV_OBJ_FLAG_HIDDEN);
    }
    uint32_t state_color = s_ui_state == UI_LISTENING
                               ? UI_DASH_ACTIVE
                               : (audio_transport_ready() ? UI_DASH_ACCENT
                                                          : UI_DASH_MUTED);
    if (s_ui_state == UI_WAITING && s_mac_connected) {
        lv_label_set_text(s_state_label, "BRIDGE OFF");
    } else {
        lv_label_set_text(s_state_label, states[s_ui_state]);
    }
    lv_obj_set_style_text_color(s_state_label, lv_color_hex(state_color), 0);
    lv_obj_remove_flag(s_state_label, LV_OBJ_FLAG_HIDDEN);
    // Every state uses the same center anchor and type size. Recording can
    // therefore add its waveform and timer without making the status jump.
    lv_obj_align_to(s_state_label, s_listening_group, LV_ALIGN_TOP_MID, 0, 0);

    if (s_ui_state == UI_LISTENING) {
        lv_obj_add_flag(s_state_dot, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(s_wave_group, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(s_listening_group, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_set_style_bg_color(s_state_dot, lv_color_hex(state_color), 0);
        lv_obj_remove_flag(s_state_dot, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(s_wave_group, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(s_listening_group, LV_OBJ_FLAG_HIDDEN);
        lv_obj_update_layout(s_screen);
        lv_obj_align_to(s_state_dot, s_state_label, LV_ALIGN_OUT_LEFT_MID, -8, 0);
    }
}

static void ui_refresh(void)
{
    if (!bsp_lvgl_lock(200)) return;
    ui_refresh_locked();
    bsp_lvgl_unlock();
}

static void ui_animation_tick(lv_timer_t *timer)
{
    static const uint8_t wave_heights[][WAVE_BAR_COUNT] = {
        { 4, 9, 17, 8, 13, 6, 11, 4 },
        { 7, 15, 26, 12, 20, 9, 17, 6 },
        { 10, 18, 12, 23, 14, 20, 8, 12 },
        { 5, 11, 20, 9, 25, 13, 18, 7 },
    };
    (void)timer;

    uint32_t now_ms = lv_tick_get();
    if (s_pet_image && s_pet_plugin && s_pet_plugin->frame_count > 0) {
        uint16_t frame_ms = s_pet_plugin->frame_ms > 0
                                ? s_pet_plugin->frame_ms
                                : UI_ANIMATION_MS;
        size_t pet_frame = (now_ms / frame_ms) % s_pet_plugin->frame_count;
        lv_image_set_src(s_pet_image, s_pet_plugin->frames[pet_frame]);
    }

    if (lv_obj_has_flag(s_listening_group, LV_OBJ_FLAG_HIDDEN)) return;

    unsigned wave_frame = (now_ms / UI_ANIMATION_MS) %
                          (sizeof(wave_heights) / sizeof(wave_heights[0]));
    for (unsigned i = 0; i < WAVE_BAR_COUNT; ++i) {
        int height = wave_heights[wave_frame][i];
        lv_obj_set_y(s_wave_bars[i], (28 - height) / 2);
        lv_obj_set_height(s_wave_bars[i], height);
    }

    TickType_t elapsed_ticks = xTaskGetTickCount() - s_listening_started_at;
    uint32_t elapsed_seconds = (uint32_t)(elapsed_ticks * portTICK_PERIOD_MS) / 1000U;
    uint32_t minutes = elapsed_seconds / 60U;
    if (minutes > 99U) minutes = 99U;
    uint32_t seconds = elapsed_seconds % 60U;
    lv_label_set_text_fmt(s_listening_timer_label, "%02lu:%02lu",
                          (unsigned long)minutes, (unsigned long)seconds);
    lv_obj_set_style_opa(s_listening_dot,
                         wave_frame == 0 ? LV_OPA_50 : LV_OPA_COVER, 0);
}

static void protocol_write(const char *message)
{
    if (s_serial_mutex) xSemaphoreTake(s_serial_mutex, portMAX_DELAY);
    printf("AIPASS:%s\n", message);
    fflush(stdout);
    if (s_serial_mutex) xSemaphoreGive(s_serial_mutex);
}

static void audio_write_frame(const int16_t *pcm, uint16_t samples,
                              uint16_t sequence)
{
    audio_frame_header_t header = {
        .payload_bytes = (uint16_t)(samples * sizeof(*pcm)),
        .sequence = sequence,
    };
    memcpy(header.magic, s_audio_magic, sizeof(header.magic));

    xSemaphoreTake(s_serial_mutex, portMAX_DELAY);
    fwrite(&header, sizeof(header), 1, stdout);
    fwrite(pcm, sizeof(*pcm), samples, stdout);
    fflush(stdout);
    xSemaphoreGive(s_serial_mutex);
}

static void audio_stream_task(void *arg)
{
    (void)arg;
    int16_t pcm[AUDIO_FRAME_SAMPLES];
    int8_t ble_pcm[AUDIO_FRAME_SAMPLES / 2];
    uint16_t sequence = 0;

    while (true) {
        // A task notification avoids waking this 8 KB audio task every 10 ms
        // while the microphone is idle. Only a real start request wakes it.
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        if (!s_audio_requested) continue;

        sequence = 0;
        bool ble_stream = ble_keyboard_connected();
        // Prefer the wireless path when BLE is connected. Besides avoiding
        // duplicate audio, this keeps a charging/debug USB cable from turning
        // the same recording into a second serial stream.
        bool usb_stream = !ble_stream && usb_serial_jtag_is_connected();
        if (usb_stream) protocol_write("AUDIO,START,16000,16,1");
        if (ble_stream) {
            ble_keyboard_audio_start(8000);
        }
        while (s_audio_requested) {
            if (bsp_audio_read(pcm, sizeof(pcm)) != ESP_OK) {
                if (usb_stream) protocol_write("AUDIO,ERROR,READ");
                s_audio_requested = false;
                break;
            }
            if (usb_stream) {
                audio_write_frame(pcm, AUDIO_FRAME_SAMPLES, sequence++);
            }
            if (ble_stream) {
                for (size_t i = 0; i < AUDIO_FRAME_SAMPLES / 2; ++i) {
                    ble_pcm[i] = (int8_t)(pcm[i * 2] >> 8);
                }
                esp_err_t err = ble_keyboard_audio_write(
                    ble_pcm, AUDIO_FRAME_SAMPLES / 2);
                // A bounded BLE queue intentionally drops stale PCM under
                // congestion. START, STOP and key reports use a separate,
                // reliable control queue and are never displaced by audio.
                (void)err;
            }
        }
        if (ble_stream) {
            ble_keyboard_audio_stop();
        }
        if (usb_stream) protocol_write("AUDIO,STOP");
    }
}

static void handle_button(const shortcut_button_event_t *event)
{
    display_activity();
    if (event->ev == BSP_BTN_PRESS) ble_keyboard_promote_advertising();
    if (event->btn == BUTTON_VOICE && event->ev == BSP_BTN_PRESS && !s_voice_held) {
        if (!audio_transport_ready()) {
            s_ui_state = UI_WAITING;
            ui_refresh();
            return;
        }
        s_voice_held = true;
        s_listening_started_at = xTaskGetTickCount();
        s_ui_state = UI_LISTENING;
        esp_err_t err = ble_keyboard_shortcut_press(SHORTCUT_ACTION_VOICE);
        if (err != ESP_OK) ESP_LOGW("shortcut_app", "Voice key down failed: %s",
                                    esp_err_to_name(err));
        // Put the shortcut-down report ahead of AUDIO_START/PCM. The audio
        // task has a higher priority and would otherwise preempt this worker
        // as soon as it was notified.
        s_audio_requested = s_audio_available;
        if (s_audio_requested && s_audio_task) xTaskNotifyGive(s_audio_task);
        protocol_write("VOICE,DOWN");
        ui_refresh();
        return;
    }
    if (event->btn == BUTTON_VOICE && event->ev == BSP_BTN_RELEASE && s_voice_held) {
        s_audio_requested = false;
        s_voice_held = false;
        s_ui_state = audio_transport_ready() ? UI_READY : UI_WAITING;
        protocol_write("VOICE,UP");
        ui_refresh();
        esp_err_t err = ble_keyboard_shortcut_release(SHORTCUT_ACTION_VOICE);
        if (err != ESP_OK) ESP_LOGW("shortcut_app", "Voice key up failed: %s",
                                    esp_err_to_name(err));
        return;
    }
    if (event->ev != BSP_BTN_CLICK) return;

    if (event->btn == BUTTON_SEND) {
        s_ui_state = UI_RETURN_SENT;
        esp_err_t err = ble_keyboard_shortcut_tap(SHORTCUT_ACTION_SEND);
        if (err != ESP_OK) ESP_LOGW("shortcut_app", "Return failed: %s",
                                    esp_err_to_name(err));
        protocol_write("KEY,RETURN");
        ui_refresh();
    } else if (event->btn == BUTTON_CLEAR) {
        s_ui_state = UI_CLEARED;
        esp_err_t err = ble_keyboard_shortcut_tap(SHORTCUT_ACTION_CLEAR);
        if (err != ESP_OK) ESP_LOGW("shortcut_app", "Clear failed: %s",
                                    esp_err_to_name(err));
        protocol_write("KEY,CLEAR");
        ui_refresh();
    }
}

static void handle_ble_status(bool connected)
{
    display_activity();
    s_mac_connected = connected;
    if (!connected && s_voice_held) {
        s_audio_requested = false;
        s_voice_held = false;
    }
    if (!connected) s_audio_host_ready = false;
    if (!connected) s_pairing_passkey = 0;
    s_ui_state = audio_transport_ready() ? UI_READY : UI_WAITING;
    ui_refresh();
}

static void handle_ble_pairing(uint32_t passkey)
{
    s_pairing_passkey = passkey;
    if (passkey != 0) display_activity();
    ui_refresh();
}

static void handle_ble_host_status(bool audio_ready, uint8_t hour, uint8_t minute,
                                   uint16_t year, uint8_t month, uint8_t day,
                                   uint8_t weekday, uint8_t codex_remaining,
                                   uint32_t daily_tokens)
{
    s_audio_host_ready = audio_ready;
    if (!audio_ready && s_voice_held) {
        s_audio_requested = false;
        s_voice_held = false;
        ble_keyboard_report(0, 0);
    }
    s_time_text[0] = (char)('0' + hour / 10);
    s_time_text[1] = (char)('0' + hour % 10);
    s_time_text[2] = ':';
    s_time_text[3] = (char)('0' + minute / 10);
    s_time_text[4] = (char)('0' + minute % 10);
    s_time_text[5] = '\0';
    if (year >= 2020 && month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        snprintf(s_date_text, sizeof(s_date_text), "%04u.%02u.%02u", year,
                 month, day);
    }
    s_weekday = weekday <= 7 ? weekday : -1;
    s_codex_remaining = codex_remaining <= 100 ? codex_remaining : -1;
    s_daily_tokens = daily_tokens <= INT32_MAX ? (int32_t)daily_tokens : -1;
    if (!s_voice_held) s_ui_state = audio_ready ? UI_READY : UI_WAITING;
    ui_refresh();
}

static void handle_host_line(const char *line)
{
    shortcut_host_message_t message;
    if (!shortcut_protocol_parse(line, &message)) return;

    s_mac_connected = true;
    s_audio_host_ready = true;
    if (message.type == SHORTCUT_HOST_TIME) {
        snprintf(s_time_text, sizeof(s_time_text), "%s", message.time_text);
    }
    if (!s_voice_held) s_ui_state = UI_READY;
    ui_refresh();
}

// Owns blocking serial output, non-blocking console input, battery I2C reads, and UI dispatch.
static void shortcut_worker(void *arg)
{
    (void)arg;
    char line[64];
    size_t line_len = 0;
    TickType_t next_battery = 0;
    TickType_t next_host_status = 0;
    uint32_t voice_transitions_handled = 0;
    bool voice_state_handled = false;

    int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
    if (flags >= 0) fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);
    protocol_write("READY");

    while (true) {
        ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(20));

        // Voice press/release transitions use an atomic counter rather than a
        // finite queue. Even if the UI/status worker is briefly busy, every
        // edge is replayed and a release can never be lost. The button callback
        // also clears s_audio_requested immediately as a local fail-safe.
        uint32_t voice_snapshot = s_voice_transition_count;
        while (voice_transitions_handled != voice_snapshot) {
            voice_state_handled = !voice_state_handled;
            const shortcut_button_event_t voice_event = {
                .kind = SHORTCUT_EVENT_BUTTON,
                .btn = BUTTON_VOICE,
                .ev = voice_state_handled ? BSP_BTN_PRESS : BSP_BTN_RELEASE,
            };
            handle_button(&voice_event);
            ++voice_transitions_handled;
        }

        shortcut_button_event_t event;
        while (xQueueReceive(s_button_queue, &event, 0) == pdTRUE) {
            handle_button(&event);
        }
        while (xQueueReceive(s_status_queue, &event, 0) == pdTRUE) {
            if (event.kind == SHORTCUT_EVENT_BLE_STATUS) {
                handle_ble_status(event.ble_connected);
            } else if (event.kind == SHORTCUT_EVENT_BLE_PAIRING) {
                handle_ble_pairing(event.pairing_passkey);
            } else if (event.kind == SHORTCUT_EVENT_BLE_HOST_STATUS) {
                handle_ble_host_status(event.audio_ready, event.hour,
                                       event.minute, event.year, event.month,
                                       event.day, event.weekday,
                                       event.codex_remaining,
                                       event.daily_tokens);
            }
        }

        char incoming[32];
        ssize_t count = read(STDIN_FILENO, incoming, sizeof(incoming));
        if (count > 0) {
            for (ssize_t i = 0; i < count; i++) {
                char ch = incoming[i];
                if (ch == '\n' || ch == '\r') {
                    if (line_len > 0) {
                        line[line_len] = '\0';
                        handle_host_line(line);
                        line_len = 0;
                    }
                } else if (line_len + 1 < sizeof(line)) {
                    line[line_len++] = ch;
                } else {
                    line_len = 0;
                }
            }
        } else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
            line_len = 0;
        }

        TickType_t now = xTaskGetTickCount();
        if (now >= next_host_status) {
            ble_keyboard_poll_host_status();
            next_host_status = now + pdMS_TO_TICKS(500);
        }
        if (s_battery_available && now >= next_battery) {
            s_battery_soc = bsp_battery_soc();
            next_battery = now + pdMS_TO_TICKS(s_deep_idle ? 30000 : 3000);
            ui_refresh();
        }
        update_backlight(now);
    }
}

esp_err_t shortcut_app_start(bool battery_available, bool audio_available)
{
    s_battery_available = battery_available;
    s_audio_available = audio_available;
    display_activity();
    s_button_queue = xQueueCreate(16, sizeof(shortcut_button_event_t));
    s_status_queue = xQueueCreate(8, sizeof(shortcut_button_event_t));
    if (!s_button_queue || !s_status_queue) return ESP_ERR_NO_MEM;
    s_serial_mutex = xSemaphoreCreateMutex();
    if (!s_serial_mutex) return ESP_ERR_NO_MEM;

    if (!bsp_lvgl_lock(1000)) return ESP_ERR_TIMEOUT;
    s_screen = lv_obj_create(NULL);
    lv_obj_remove_flag(s_screen, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_style_bg_color(s_screen, lv_color_hex(UI_DASH_BG), 0);
    lv_obj_set_style_border_width(s_screen, 0, 0);
    lv_obj_set_style_pad_all(s_screen, 0, 0);

    s_time_label = ui_pixel_label(s_screen, "--:--",
                                  &lv_font_montserrat_16, UI_DASH_TEXT);
    lv_obj_align(s_time_label, LV_ALIGN_TOP_LEFT, 16, 8);
    s_date_label = ui_pixel_label(s_screen, "----.--.--",
                                  &lv_font_montserrat_10, UI_DASH_MUTED);
    lv_obj_align(s_date_label, LV_ALIGN_TOP_LEFT, 16, 34);
    s_battery_label = ui_pixel_label(s_screen, "--%", &lv_font_montserrat_16,
                                     UI_DASH_TEXT);
    lv_obj_align(s_battery_label, LV_ALIGN_TOP_RIGHT, -16, 8);
    lv_obj_t *battery_outline = ui_dash_container(s_screen, 201, 35, 22, 10);
    lv_obj_set_style_border_width(battery_outline, 1, 0);
    lv_obj_set_style_border_color(battery_outline,
                                  lv_color_hex(UI_DASH_MUTED), 0);
    lv_obj_set_style_radius(battery_outline, 2, 0);
    s_battery_fill = ui_dash_block(battery_outline, 2, 2, 16, 4,
                                   UI_DASH_TEXT, 0);
    ui_dash_block(s_screen, 223, 38, 2, 4, UI_DASH_MUTED, 0);
    ui_dash_block(s_screen, 16, 60, 208, 1, UI_DASH_SURFACE, 0);

    lv_obj_t *codex_title = ui_pixel_label(s_screen, AI_PROVIDER_QUOTA_TITLE,
                                           &lv_font_montserrat_12,
                                           UI_DASH_MUTED);
    lv_obj_align(codex_title, LV_ALIGN_TOP_LEFT, 16, 74);
    lv_obj_t *codex_context = ui_pixel_label(s_screen, AI_PROVIDER_QUOTA_CONTEXT,
                                             &lv_font_montserrat_10,
                                             0x486273);
    lv_obj_align(codex_context, LV_ALIGN_TOP_LEFT, 16, 91);
    s_codex_label = ui_pixel_label(s_screen, "--%", &lv_font_montserrat_16,
                                   UI_DASH_TEXT);
    lv_obj_align(s_codex_label, LV_ALIGN_TOP_RIGHT, -16, 75);
    s_codex_bar = lv_bar_create(s_screen);
    lv_obj_set_pos(s_codex_bar, 24, 107);
    lv_obj_set_size(s_codex_bar, 192, 4);
    lv_bar_set_range(s_codex_bar, 0, 100);
    lv_obj_set_style_radius(s_codex_bar, 1, LV_PART_MAIN);
    lv_obj_set_style_radius(s_codex_bar, 1, LV_PART_INDICATOR);
    lv_obj_set_style_bg_color(s_codex_bar, lv_color_hex(UI_DASH_SURFACE),
                              LV_PART_MAIN);
    lv_obj_set_style_bg_opa(s_codex_bar, LV_OPA_COVER, LV_PART_MAIN);

    ui_dash_block(s_screen, 16, 140, 208, 1, UI_DASH_SURFACE, 0);

    lv_obj_t *tokens_title = ui_pixel_label(s_screen, AI_PROVIDER_DAILY_TITLE,
                                            &lv_font_montserrat_12,
                                            UI_DASH_MUTED);
    lv_obj_align(tokens_title, LV_ALIGN_TOP_LEFT, 16, 154);
    lv_obj_t *tokens_context = ui_pixel_label(s_screen, AI_PROVIDER_DAILY_CONTEXT,
                                              &lv_font_montserrat_10,
                                              0x486273);
    lv_obj_align(tokens_context, LV_ALIGN_TOP_LEFT, 16, 171);
    s_daily_tokens_label = ui_pixel_label(s_screen, "--",
                                           &lv_font_montserrat_16,
                                           UI_DASH_TEXT);
    lv_obj_align(s_daily_tokens_label, LV_ALIGN_TOP_RIGHT, -16, 155);
    s_daily_tokens_bar = lv_bar_create(s_screen);
    lv_obj_set_pos(s_daily_tokens_bar, 24, 187);
    lv_obj_set_size(s_daily_tokens_bar, 192, 4);
    lv_bar_set_range(s_daily_tokens_bar, 0, 1000);
    lv_obj_set_style_radius(s_daily_tokens_bar, 1, LV_PART_MAIN);
    lv_obj_set_style_radius(s_daily_tokens_bar, 1, LV_PART_INDICATOR);
    lv_obj_set_style_bg_color(s_daily_tokens_bar, lv_color_hex(UI_DASH_SURFACE),
                              LV_PART_MAIN);
    lv_obj_set_style_bg_color(s_daily_tokens_bar, lv_color_hex(UI_DASH_TOKEN),
                              LV_PART_INDICATOR);
    lv_obj_set_style_bg_opa(s_daily_tokens_bar, LV_OPA_COVER, LV_PART_MAIN);

    s_pet_plugin = shortcut_pet_plugin_get();
    if (s_pet_plugin && s_pet_plugin->frames && s_pet_plugin->frame_count > 0) {
        s_pet_image = lv_image_create(s_screen);
        lv_image_set_src(s_pet_image, s_pet_plugin->frames[0]);
        lv_obj_set_pos(s_pet_image, s_pet_plugin->x, s_pet_plugin->y);
    }

    s_wave_group = ui_dash_container(s_screen, 132, 236, 94, 28);
    static const uint8_t initial_wave_heights[WAVE_BAR_COUNT] = {
        9, 18, 26, 15, 23, 12, 20, 8
    };
    for (unsigned i = 0; i < WAVE_BAR_COUNT; ++i) {
        int height = initial_wave_heights[i];
        s_wave_bars[i] = ui_dash_block(s_wave_group, 17 + (int)i * 8,
                                       (28 - height) / 2, 4, height,
                                       UI_DASH_ACTIVE, 2);
    }

    s_listening_group = ui_dash_container(s_screen, 132, 269, 94, 41);
    s_listening_dot = ui_dash_block(s_listening_group, 22, 31, 7, 7,
                                    UI_DASH_ACTIVE, 4);
    s_listening_timer_label = ui_pixel_label(s_listening_group, "00:00",
                                             &lv_font_montserrat_10,
                                             UI_DASH_ACTIVE_MUTED);
    lv_obj_set_pos(s_listening_timer_label, 35, 28);

    s_state_dot = ui_dash_block(s_screen, 164, 283, 8, 8,
                                UI_DASH_MUTED, 4);
    s_state_label = ui_pixel_label(s_screen, "PAIR", &lv_font_montserrat_20,
                                   UI_DASH_MUTED);

    s_pairing_group = ui_dash_block(s_screen, 16, 218, 208, 86,
                                    UI_DASH_SURFACE, 8);
    lv_obj_t *pairing_title = ui_pixel_label(s_pairing_group, "PAIRING CODE",
                                             &lv_font_montserrat_12,
                                             UI_DASH_MUTED);
    lv_obj_align(pairing_title, LV_ALIGN_TOP_MID, 0, 11);
    s_pairing_code_label = ui_pixel_label(s_pairing_group, "000000",
                                          &lv_font_montserrat_32,
                                          UI_DASH_ACCENT);
    lv_obj_align(s_pairing_code_label, LV_ALIGN_BOTTOM_MID, 0, -9);
    lv_obj_add_flag(s_pairing_group, LV_OBJ_FLAG_HIDDEN);
    ui_refresh_locked();
    lv_screen_load(s_screen);
    s_animation_timer = lv_timer_create(ui_animation_tick, UI_ANIMATION_MS, NULL);
    bsp_lvgl_unlock();

    if (!s_animation_timer) return ESP_ERR_NO_MEM;

    if (xTaskCreate(shortcut_worker, "shortcut_io", 4096, NULL, 5,
                    &s_shortcut_task) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }
    if (s_audio_available &&
        xTaskCreate(audio_stream_task, "audio_stream", 8192, NULL, 6,
                    &s_audio_task) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

void shortcut_app_button(bsp_btn_t btn, bsp_btn_ev_t ev, void *user)
{
    (void)user;
    if (!s_button_queue) return;

    if (btn == BUTTON_VOICE &&
        (ev == BSP_BTN_PRESS || ev == BSP_BTN_RELEASE)) {
        bool down = ev == BSP_BTN_PRESS;
        if (down != s_voice_button_down) {
            s_voice_button_down = down;
            ++s_voice_transition_count;
            // Stop microphone reads at the physical release edge, without
            // waiting for UI, serial, battery or BLE work to finish.
            if (!down) s_audio_requested = false;
            if (s_shortcut_task) xTaskNotifyGive(s_shortcut_task);
        }
        return;
    }

    const shortcut_button_event_t event = {
        .kind = SHORTCUT_EVENT_BUTTON,
        .btn = btn,
        .ev = ev,
    };
    if (xQueueSend(s_button_queue, &event, 0) != pdTRUE) {
        ESP_LOGW("shortcut_app", "Button event queue full: btn=%u ev=%u",
                 (unsigned)btn, (unsigned)ev);
    }
    if (s_shortcut_task) xTaskNotifyGive(s_shortcut_task);
}

void shortcut_app_ble_connected(bool connected, void *user)
{
    (void)user;
    if (!s_status_queue) return;
    const shortcut_button_event_t event = {
        .kind = SHORTCUT_EVENT_BLE_STATUS,
        .ble_connected = connected,
    };
    if (xQueueSend(s_status_queue, &event, 0) != pdTRUE) {
        ESP_LOGW("shortcut_app", "BLE status event queue full");
    }
    if (s_shortcut_task) xTaskNotifyGive(s_shortcut_task);
}

void shortcut_app_ble_pairing(uint32_t passkey, void *user)
{
    (void)user;
    if (!s_status_queue) return;
    const shortcut_button_event_t event = {
        .kind = SHORTCUT_EVENT_BLE_PAIRING,
        .pairing_passkey = passkey,
    };
    if (xQueueSend(s_status_queue, &event, 0) != pdTRUE) {
        ESP_LOGW("shortcut_app", "BLE pairing event queue full");
    }
    if (s_shortcut_task) xTaskNotifyGive(s_shortcut_task);
}

void shortcut_app_ble_host_status(bool audio_ready, uint8_t hour,
                                  uint8_t minute, uint16_t year,
                                  uint8_t month, uint8_t day,
                                  uint8_t weekday,
                                  uint8_t codex_remaining,
                                  uint32_t daily_tokens, void *user)
{
    (void)user;
    if (!s_status_queue) return;
    const shortcut_button_event_t event = {
        .kind = SHORTCUT_EVENT_BLE_HOST_STATUS,
        .audio_ready = audio_ready,
        .hour = hour,
        .minute = minute,
        .year = year,
        .month = month,
        .day = day,
        .weekday = weekday,
        .codex_remaining = codex_remaining,
        .daily_tokens = daily_tokens,
    };
    if (xQueueSend(s_status_queue, &event, 0) != pdTRUE) {
        ESP_LOGW("shortcut_app", "Host status event queue full");
    }
    if (s_shortcut_task) xTaskNotifyGive(s_shortcut_task);
}
