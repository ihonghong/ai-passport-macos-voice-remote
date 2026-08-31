#include "ble_keyboard.h"

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include "esp_bt.h"
#include "esp_hid_common.h"
#include "esp_hidd.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_random.h"
#include "nvs_flash.h"
#include "nvs.h"

#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/ble_hs.h"
#include "host/ble_hs_adv.h"
#include "host/ble_store.h"
#include "nimble/ble.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"

#include <stddef.h>
#include <string.h>

#define HID_SERVICE_UUID 0x1812
#define HID_REPORT_CHARACTERISTIC_UUID 0x2A4D
#define KEYBOARD_REPORT_ID 1
#define AUDIO_REPORT_ID 2
#define HOST_STATUS_REPORT_ID 3
#define AUDIO_REPORT_BYTES 176
#define AUDIO_PACKET_HEADER_BYTES 4
#define AUDIO_PACKET_PAYLOAD_BYTES (AUDIO_REPORT_BYTES - AUDIO_PACKET_HEADER_BYTES)
#define CONTROL_TX_QUEUE_LENGTH 8
#define AUDIO_TX_QUEUE_LENGTH 2
#define CONTROL_TX_RETRIES 20
#define TX_TASK_STACK_SIZE 4096
#define TX_TASK_PRIORITY 7
#define IDLE_PROFILE_COOLDOWN_MS 3000
#define KEYMAP_NVS_NAMESPACE "aipass_cfg"
#define KEYMAP_NVS_KEY "keymap_v1"

// Advertising is intentionally fast only during the reconnect window. A slow
// forever phase avoids 20-33 radio wakeups per second when the paired Mac is
// absent, while a physical button can promote it back to the fast phase.
#define ADV_FAST_DURATION_MS 30000
#define ADV_FAST_MIN_MS 30
#define ADV_FAST_MAX_MS 50
#define ADV_SLOW_MIN_MS 500
#define ADV_SLOW_MAX_MS 1000

// BLE connection interval units are 1.25 ms and supervision timeout units are
// 10 ms. Peripheral latency lets an idle device skip empty events; when it has
// a key report ready it can still use the next 80-100 ms base event.
#define CONN_IDLE_MIN_UNITS 64
#define CONN_IDLE_MAX_UNITS 80
#define CONN_IDLE_LATENCY 4
#define CONN_ACTIVE_MIN_UNITS 12
#define CONN_ACTIVE_MAX_UNITS 24
#define CONN_ACTIVE_LATENCY 0
#define CONN_SUPERVISION_TIMEOUT_UNITS 500

enum {
    AUDIO_PACKET_START = 1,
    AUDIO_PACKET_PCM = 2,
    AUDIO_PACKET_STOP = 3,
};

typedef enum {
    TX_KEYBOARD_REPORT = 0,
    TX_AUDIO_START,
    TX_AUDIO_PCM,
    TX_AUDIO_STOP,
} tx_kind_t;

typedef struct {
    tx_kind_t kind;
    uint16_t length;
    uint8_t data[AUDIO_REPORT_BYTES];
} tx_message_t;

static const char *TAG = "ble_keyboard";
static const char *DEVICE_NAME = "AI Passport";

static esp_hidd_dev_t *s_hid_dev;
static ble_keyboard_connection_cb_t s_connection_cb;
static ble_keyboard_pairing_cb_t s_pairing_cb;
static ble_keyboard_host_status_cb_t s_host_status_cb;
static void *s_connection_user;
static bool s_connected;
static uint8_t s_own_addr_type;
static uint16_t s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static bool s_restart_fast_advertising;
static bool s_desired_streaming;
static bool s_conn_update_pending;
static bool s_pending_streaming;
static int8_t s_applied_streaming = -1;
static uint32_t s_pairing_passkey;
static uint16_t s_audio_sequence;
static uint16_t s_host_status_handle;
static uint16_t s_keyboard_input_handle;
static uint16_t s_audio_input_handle;
static QueueHandle_t s_control_tx_queue;
static QueueHandle_t s_audio_tx_queue;
static TaskHandle_t s_tx_task;
static uint32_t s_audio_packets_queued;
static uint32_t s_audio_packets_dropped;
static bool s_idle_profile_pending;
static TickType_t s_idle_profile_deadline;
static uint8_t s_last_host_hour = 0xff;
static uint8_t s_last_host_minute = 0xff;
static uint8_t s_last_host_ready = 0xff;
static uint16_t s_last_host_year = UINT16_MAX;
static uint8_t s_last_host_month = 0xff;
static uint8_t s_last_host_day = 0xff;
static uint8_t s_last_host_weekday = 0xff;
static uint8_t s_last_codex_remaining = 0xff;
static uint8_t s_last_daily_token_bucket = 0xff;
static shortcut_keymap_t s_keymap;

static void load_keymap(void)
{
    s_keymap = shortcut_keymap_default();
    nvs_handle_t handle;
    esp_err_t err = nvs_open(KEYMAP_NVS_NAMESPACE, NVS_READONLY, &handle);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGI(TAG, "Shortcut keymap: public defaults");
        return;
    }
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "Unable to open shortcut keymap: %s", esp_err_to_name(err));
        return;
    }

    uint8_t record[SHORTCUT_KEYMAP_WIRE_BYTES];
    size_t length = sizeof(record);
    err = nvs_get_blob(handle, KEYMAP_NVS_KEY, record, &length);
    nvs_close(handle);
    shortcut_keymap_t stored;
    if (err == ESP_OK) {
        if (shortcut_keymap_decode(record, length, &stored)) {
            s_keymap = stored;
            ESP_LOGI(TAG, "Shortcut keymap: restored from NVS");
        } else {
            ESP_LOGW(TAG, "Ignoring invalid shortcut keymap record");
        }
    } else if (err != ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGW(TAG, "Ignoring invalid shortcut keymap: %s",
                 esp_err_to_name(err));
    }
}

static esp_err_t save_keymap(const shortcut_keymap_t *keymap)
{
    uint8_t record[SHORTCUT_KEYMAP_WIRE_BYTES];
    if (!shortcut_keymap_encode(keymap, record)) return ESP_ERR_INVALID_ARG;

    nvs_handle_t handle;
    esp_err_t err = nvs_open(KEYMAP_NVS_NAMESPACE, NVS_READWRITE, &handle);
    if (err != ESP_OK) return err;
    err = nvs_set_blob(handle, KEYMAP_NVS_KEY, record, sizeof(record));
    if (err == ESP_OK) err = nvs_commit(handle);
    nvs_close(handle);
    if (err == ESP_OK) s_keymap = *keymap;
    return err;
}

static int configure_keyboard_identity(void)
{
    uint8_t base_mac[6];
    uint8_t random_addr[6];
    esp_err_t err = esp_read_mac(base_mac, ESP_MAC_BT);
    if (err != ESP_OK) return err;

    // NimBLE stores addresses least-significant byte first. Derive a stable
    // static-random identity from this board's public MAC so macOS does not
    // reuse the stock firmware's cached, non-HID GATT database.
    for (size_t i = 0; i < sizeof(random_addr); ++i) {
        random_addr[i] = base_mac[sizeof(random_addr) - 1 - i];
    }
    // This revision adds a vendor HID collection. Use a fresh, stable identity
    // so macOS does not reuse the older keyboard-only report-map cache.
    random_addr[0] ^= 0x5a;
    random_addr[5] = (random_addr[5] & 0x0f) | 0xf0;

    int rc = ble_hs_id_set_rnd(random_addr);
    if (rc != 0) return rc;
    s_own_addr_type = BLE_OWN_ADDR_RANDOM;
    ESP_LOGI(TAG, "BLE keyboard identity: %02x:%02x:%02x:%02x:%02x:%02x",
             random_addr[5], random_addr[4], random_addr[3],
             random_addr[2], random_addr[1], random_addr[0]);
    return 0;
}

// Standard boot-compatible keyboard report: modifiers, reserved byte and six
// simultaneous key slots. Report ID is 1.
static const uint8_t s_keyboard_report_map[] = {
    0x05, 0x01,       // Usage Page (Generic Desktop)
    0x09, 0x06,       // Usage (Keyboard)
    0xA1, 0x01,       // Collection (Application)
    0x85, 0x01,       //   Report ID (1)
    0x05, 0x07,       //   Usage Page (Keyboard)
    0x19, 0xE0,       //   Usage Minimum (Left Control)
    0x29, 0xE7,       //   Usage Maximum (Right GUI)
    0x15, 0x00,       //   Logical Minimum (0)
    0x25, 0x01,       //   Logical Maximum (1)
    0x75, 0x01,       //   Report Size (1)
    0x95, 0x08,       //   Report Count (8)
    0x81, 0x02,       //   Input (Data, Variable, Absolute)
    0x95, 0x01,       //   Report Count (1)
    0x75, 0x08,       //   Report Size (8)
    0x81, 0x03,       //   Input (Constant)
    0x95, 0x05,       //   Report Count (5)
    0x75, 0x01,       //   Report Size (1)
    0x05, 0x08,       //   Usage Page (LEDs)
    0x19, 0x01,       //   Usage Minimum (Num Lock)
    0x29, 0x05,       //   Usage Maximum (Kana)
    0x91, 0x02,       //   Output (Data, Variable, Absolute)
    0x95, 0x01,       //   Report Count (1)
    0x75, 0x03,       //   Report Size (3)
    0x91, 0x03,       //   Output (Constant)
    0x95, 0x06,       //   Report Count (6)
    0x75, 0x08,       //   Report Size (8)
    0x15, 0x00,       //   Logical Minimum (0)
    0x25, 0x65,       //   Logical Maximum (101)
    0x05, 0x07,       //   Usage Page (Keyboard)
    0x19, 0x00,       //   Usage Minimum (0)
    0x29, 0x65,       //   Usage Maximum (101)
    0x81, 0x00,       //   Input (Data, Array, Absolute)
    0xC0,             // End Collection

    // Vendor-defined transport. Report 2 carries fixed-size microphone
    // packets from the Passport; report 3 carries Mac time/bridge status back.
    0x06, 0x00, 0xFF, // Usage Page (Vendor Defined 0xFF00)
    0x09, 0x01,       // Usage (1)
    0xA1, 0x01,       // Collection (Application)
    0x85, 0x02,       //   Report ID (2: microphone input)
    0x15, 0x00,       //   Logical Minimum (0)
    0x26, 0xFF, 0x00, //   Logical Maximum (255)
    0x75, 0x08,       //   Report Size (8)
    0x95, 0xB0,       //   Report Count (176)
    0x81, 0x02,       //   Input (Data, Variable, Absolute)
    0x85, 0x03,       //   Report ID (3: host status output)
    0x95, 0x08,       //   Report Count (8)
    0x91, 0x02,       //   Output (Data, Variable, Absolute)
    0xC0,             // End Collection
};

static esp_hid_raw_report_map_t s_report_maps[] = {
    {
        .data = s_keyboard_report_map,
        .len = sizeof(s_keyboard_report_map),
    },
};

static esp_hid_device_config_t s_hid_config = {
    .vendor_id = 0x303A,
    .product_id = 0x4002,
    .version = 0x0101,
    .device_name = "AI Passport",
    .manufacturer_name = "FoloToy",
    .serial_number = "AI-PASSPORT",
    .report_maps = s_report_maps,
    .report_maps_len = 1,
};

static void notify_connection(bool connected)
{
    s_connected = connected;
    if (!connected) {
        s_last_host_hour = 0xff;
        s_last_host_minute = 0xff;
        s_last_host_ready = 0xff;
        s_last_host_year = UINT16_MAX;
        s_last_host_month = 0xff;
        s_last_host_day = 0xff;
        s_last_host_weekday = 0xff;
        s_last_codex_remaining = 0xff;
        s_last_daily_token_bucket = 0xff;
    }
    if (s_connection_cb) s_connection_cb(connected, s_connection_user);
}

static void notify_pairing_passkey(uint32_t passkey)
{
    s_pairing_passkey = passkey;
    if (s_pairing_cb) s_pairing_cb(passkey, s_connection_user);
}

static bool is_leap_year(uint16_t year)
{
    return (year % 4U == 0U && year % 100U != 0U) || year % 400U == 0U;
}

static void date_from_days_since_2020(uint16_t days, uint16_t *year,
                                      uint8_t *month, uint8_t *day,
                                      uint8_t *weekday)
{
    static const uint8_t month_days[] = {
        31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
    };
    uint16_t day_offset = days;
    uint16_t result_year = 2020;
    while (days >= (is_leap_year(result_year) ? 366U : 365U)) {
        days -= is_leap_year(result_year) ? 366U : 365U;
        ++result_year;
    }
    uint8_t result_month = 1;
    while (result_month <= 12) {
        uint16_t days_in_month = month_days[result_month - 1];
        if (result_month == 2 && is_leap_year(result_year)) ++days_in_month;
        if (days < days_in_month) break;
        days -= days_in_month;
        ++result_month;
    }
    *year = result_year;
    *month = result_month;
    *day = (uint8_t)days + 1U;
    // 2020-01-01 was Wednesday; weekdays use Monday=1 through Sunday=7.
    *weekday = (uint8_t)((day_offset + 2U) % 7U) + 1U;
}

static void consume_host_output(const uint8_t *data, size_t length)
{
    shortcut_keymap_t keymap;
    if (shortcut_keymap_decode(data, length, &keymap)) {
        if (memcmp(&keymap, &s_keymap, sizeof(keymap)) == 0) return;
        esp_err_t err = save_keymap(&keymap);
        if (err == ESP_OK) {
            ESP_LOGI(TAG, "Shortcut keymap updated");
        } else {
            ESP_LOGW(TAG, "Unable to persist shortcut keymap: %s",
                     esp_err_to_name(err));
        }
        return;
    }
    if (length < 8 || data[0] != 0xA5 || data[1] != 'A' ||
        !s_host_status_cb) return;

    uint8_t hour = 0xff;
    uint8_t minute = 0xff;
    uint8_t ready = 0;
    uint16_t year = 0;
    uint8_t month = 0;
    uint8_t day = 0;
    uint8_t weekday = 0xff;
    uint8_t codex_remaining = 0xff;
    uint8_t daily_token_bucket = 0x7f;

    if (data[2] == 'D') {
        uint64_t packed = 0;
        for (unsigned i = 0; i < 5; ++i) {
            packed |= (uint64_t)data[3 + i] << (i * 8U);
        }
        uint16_t days_since_2020 = packed & 0x3fffU;
        uint16_t minutes_since_midnight = (packed >> 14) & 0x7ffU;
        if (minutes_since_midnight >= 24U * 60U) return;
        hour = minutes_since_midnight / 60U;
        minute = minutes_since_midnight % 60U;
        ready = (packed >> 25) & 1U;
        codex_remaining = (packed >> 26) & 0x7fU;
        daily_token_bucket = (packed >> 33) & 0x7fU;
        if (codex_remaining > 100) codex_remaining = 0xff;
        date_from_days_since_2020(days_since_2020, &year, &month, &day,
                                  &weekday);
    } else if (data[2] == 'I' && (data[3] & 0x0f) == 2 &&
               data[4] < 24 && data[5] < 60) {
        // Backward compatibility with Bridge v2 while installed copies update.
        hour = data[4];
        minute = data[5];
        ready = (data[6] & 0x80) != 0;
        daily_token_bucket = data[6] & 0x7f;
        weekday = data[3] >> 4;
        if (weekday < 1 || weekday > 7) weekday = 0xff;
        codex_remaining = data[7] <= 100 ? data[7] : 0xff;
    } else {
        return;
    }

    if (hour == s_last_host_hour && minute == s_last_host_minute &&
        ready == s_last_host_ready &&
        year == s_last_host_year && month == s_last_host_month &&
        day == s_last_host_day &&
        weekday == s_last_host_weekday &&
        codex_remaining == s_last_codex_remaining &&
        daily_token_bucket == s_last_daily_token_bucket) {
        return;
    }
    s_last_host_hour = hour;
    s_last_host_minute = minute;
    s_last_host_ready = ready;
    s_last_host_year = year;
    s_last_host_month = month;
    s_last_host_day = day;
    s_last_host_weekday = weekday;
    s_last_codex_remaining = codex_remaining;
    s_last_daily_token_bucket = daily_token_bucket;
    uint32_t daily_tokens = daily_token_bucket < 0x7f
                                ? daily_token_bucket * 10000000U
                                : UINT32_MAX;
    ESP_LOGI(TAG,
             "Host status: %04u-%02u-%02u %02u:%02u weekday=%u audio=%u codex=%u daily=%lu",
             year, month, day, hour, minute, weekday, ready, codex_remaining,
             (unsigned long)daily_tokens);
    s_host_status_cb(ready, hour, minute, year, month, day, weekday,
                     codex_remaining, daily_tokens, s_connection_user);
}

static uint16_t find_report_handle(uint16_t hid_service_handle,
                                   uint8_t report_id, uint8_t report_type)
{
    // Each HID Report characteristic has a 0x2908 Report Reference
    // descriptor containing {report_id, report_type}. The Report value handle
    // is immediately before its descriptor in ESP-IDF's NimBLE HID service.
    for (uint16_t handle = hid_service_handle;
         handle < hid_service_handle + 48; ++handle) {
        struct os_mbuf *om = NULL;
        if (ble_att_svr_read_local(handle, &om) != 0 || !om) continue;
        uint8_t reference[2] = {0};
        uint16_t length = 0;
        int rc = ble_hs_mbuf_to_flat(om, reference, sizeof(reference), &length);
        os_mbuf_free_chain(om);
        if (rc == 0 && length == sizeof(reference) &&
            reference[0] == report_id && reference[1] == report_type &&
            handle > 0) {
            // Input reports also have an auto-generated CCC descriptor, so
            // their value is not necessarily descriptor_handle - 1. Locate
            // the preceding Characteristic Declaration (0x2803), which
            // contains the authoritative value handle and UUID.
            for (uint16_t distance = 1; distance <= 4 && handle > distance;
                 ++distance) {
                struct os_mbuf *decl = NULL;
                if (ble_att_svr_read_local(handle - distance, &decl) != 0 ||
                    !decl) {
                    continue;
                }
                uint8_t value[7] = {0};
                uint16_t value_length = 0;
                int decl_rc = ble_hs_mbuf_to_flat(decl, value, sizeof(value),
                                                  &value_length);
                os_mbuf_free_chain(decl);
                if (decl_rc == 0 && value_length >= 5 &&
                    ((uint16_t)value[3] | ((uint16_t)value[4] << 8)) ==
                        HID_REPORT_CHARACTERISTIC_UUID) {
                    return (uint16_t)value[1] | ((uint16_t)value[2] << 8);
                }
            }
            return report_type == ESP_HID_REPORT_TYPE_OUTPUT ? handle - 1 : 0;
        }
    }
    return 0;
}

static uint16_t find_host_status_handle(uint16_t hid_service_handle)
{
    return find_report_handle(hid_service_handle, HOST_STATUS_REPORT_ID,
                              ESP_HID_REPORT_TYPE_OUTPUT);
}

static int start_advertising(bool fast);

static void request_desired_connection_profile(void)
{
    if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE || s_conn_update_pending ||
        s_applied_streaming == (int8_t)s_desired_streaming) {
        return;
    }

    bool streaming = s_desired_streaming;
    const struct ble_gap_upd_params params = {
        .itvl_min = streaming ? CONN_ACTIVE_MIN_UNITS : CONN_IDLE_MIN_UNITS,
        .itvl_max = streaming ? CONN_ACTIVE_MAX_UNITS : CONN_IDLE_MAX_UNITS,
        .latency = streaming ? CONN_ACTIVE_LATENCY : CONN_IDLE_LATENCY,
        .supervision_timeout = CONN_SUPERVISION_TIMEOUT_UNITS,
        .min_ce_len = BLE_GAP_INITIAL_CONN_MIN_CE_LEN,
        .max_ce_len = BLE_GAP_INITIAL_CONN_MAX_CE_LEN,
    };
    int rc = ble_gap_update_params(s_conn_handle, &params);
    if (rc == 0) {
        s_conn_update_pending = true;
        s_pending_streaming = streaming;
        ESP_LOGI(TAG,
                 "Requested %s BLE profile: interval=%u-%u x1.25ms latency=%u",
                 streaming ? "streaming" : "idle", params.itvl_min,
                 params.itvl_max, params.latency);
    } else {
        // A central may reject or already be updating parameters. Keep the
        // current link; a later idle/streaming transition can request again.
        ESP_LOGW(TAG, "BLE profile request deferred/rejected: %d", rc);
    }
}

static esp_err_t send_input_notification(uint16_t value_handle,
                                         const tx_message_t *message)
{
    if (!ble_keyboard_connected() || !value_handle) {
        return ESP_ERR_INVALID_STATE;
    }

    struct os_mbuf *om = ble_hs_mbuf_from_flat(message->data, message->length);
    if (!om) return ESP_ERR_NO_MEM;

    // The ESP-IDF HID helper re-reads the protocol-mode characteristic before
    // every report. Under sustained audio traffic that local ATT read can fail
    // even while the connection remains healthy. macOS uses report protocol,
    // so cached Report value handles avoid that extra failure point.
    int rc = ble_gatts_notify_custom(s_conn_handle, value_handle, om);
    return rc == 0 ? ESP_OK : ESP_FAIL;
}

static esp_err_t send_control_notification(const tx_message_t *message)
{
    esp_err_t err = ESP_FAIL;
    for (unsigned attempt = 0; attempt < CONTROL_TX_RETRIES; ++attempt) {
        if (!ble_keyboard_connected()) return ESP_ERR_INVALID_STATE;

        if (message->kind == TX_KEYBOARD_REPORT) {
            err = send_input_notification(s_keyboard_input_handle, message);
        } else {
            err = send_input_notification(s_audio_input_handle, message);
        }
        if (err == ESP_OK) return ESP_OK;

        // A bounded backoff lets the controller return completed-packet
        // credits. Control reports are rare and must win over disposable PCM.
        unsigned delay_ms = 4U * (attempt + 1U);
        if (delay_ms > 20U) delay_ms = 20U;
        vTaskDelay(pdMS_TO_TICKS(delay_ms));
    }
    return err;
}

static void tx_task(void *arg)
{
    (void)arg;
    tx_message_t message;

    while (true) {
        TickType_t wait = portMAX_DELAY;
        if (s_idle_profile_pending) {
            TickType_t now = xTaskGetTickCount();
            wait = (int32_t)(now - s_idle_profile_deadline) >= 0
                       ? 0
                       : s_idle_profile_deadline - now;
        }
        ulTaskNotifyTake(pdTRUE, wait);

        while (true) {
            // Drain control first. At most one already-popped PCM packet can
            // precede a newly queued key-up or AUDIO_STOP report.
            if (xQueueReceive(s_control_tx_queue, &message, 0) == pdTRUE) {
                esp_err_t err = send_control_notification(&message);
                if (err != ESP_OK) {
                    ESP_LOGE(TAG, "Critical HID report %u failed: %s",
                             (unsigned)message.kind, esp_err_to_name(err));
                }
                if (message.kind == TX_AUDIO_START) {
                    s_idle_profile_pending = false;
                } else if (message.kind == TX_AUDIO_STOP) {
                    s_idle_profile_pending = true;
                    s_idle_profile_deadline =
                        xTaskGetTickCount() +
                        pdMS_TO_TICKS(IDLE_PROFILE_COOLDOWN_MS);
                    ESP_LOGI(TAG,
                             "Audio stream complete: queued=%lu dropped=%lu tx_stack=%u",
                             (unsigned long)s_audio_packets_queued,
                             (unsigned long)s_audio_packets_dropped,
                             (unsigned)uxTaskGetStackHighWaterMark(NULL));
                }
                continue;
            }

            if (xQueueReceive(s_audio_tx_queue, &message, 0) == pdTRUE) {
                if (send_input_notification(s_audio_input_handle, &message) !=
                    ESP_OK) {
                    ++s_audio_packets_dropped;
                }
                continue;
            }

            if (s_idle_profile_pending) {
                TickType_t now = xTaskGetTickCount();
                if ((int32_t)(now - s_idle_profile_deadline) >= 0) {
                    s_idle_profile_pending = false;
                    s_desired_streaming = false;
                    request_desired_connection_profile();
                }
            }
            break;
        }
    }
}

static esp_err_t queue_tx(const tx_message_t *message, bool control)
{
    QueueHandle_t queue = control ? s_control_tx_queue : s_audio_tx_queue;
    if (!queue || !s_tx_task) return ESP_ERR_INVALID_STATE;

    TickType_t wait = control ? pdMS_TO_TICKS(50) : 0;
    if (xQueueSend(queue, message, wait) != pdTRUE) {
        if (!control) ++s_audio_packets_dropped;
        return ESP_ERR_TIMEOUT;
    }
    xTaskNotifyGive(s_tx_task);
    return ESP_OK;
}

static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        ESP_LOGI(TAG, "BLE connection attempt: status=%d",
                 event->connect.status);
        if (event->connect.status != 0) {
            ESP_LOGW(TAG, "BLE connect failed: %d", event->connect.status);
            start_advertising(true);
        } else {
            s_conn_handle = event->connect.conn_handle;
            s_conn_update_pending = false;
            s_applied_streaming = -1;
            s_desired_streaming = false;
            notify_pairing_passkey(0);
        }
        return 0;
    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "BLE disconnected: %d", event->disconnect.reason);
        s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        s_conn_update_pending = false;
        s_applied_streaming = -1;
        s_desired_streaming = false;
        s_idle_profile_pending = false;
        if (s_control_tx_queue) xQueueReset(s_control_tx_queue);
        if (s_audio_tx_queue) xQueueReset(s_audio_tx_queue);
        s_restart_fast_advertising = false;
        notify_pairing_passkey(0);
        start_advertising(true);
        return 0;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        if (s_conn_handle != BLE_HS_CONN_HANDLE_NONE) return 0;
        if (s_restart_fast_advertising) {
            s_restart_fast_advertising = false;
            start_advertising(true);
        } else {
            start_advertising(false);
        }
        return 0;
    case BLE_GAP_EVENT_CONN_UPDATE: {
        struct ble_gap_conn_desc desc;
        if (ble_gap_conn_find(event->conn_update.conn_handle, &desc) == 0) {
            ESP_LOGI(TAG,
                     "BLE connection update: status=%d interval=%u x1.25ms latency=%u timeout=%u x10ms",
                     event->conn_update.status, desc.conn_itvl,
                     desc.conn_latency, desc.supervision_timeout);
        } else {
            ESP_LOGW(TAG,
                     "BLE connection update status=%d; descriptor unavailable",
                     event->conn_update.status);
        }
        if (s_conn_update_pending) {
            // Treat a rejected or colliding request as an accepted fallback so
            // it is not retried against an in-flight controller procedure. A
            // later idle/streaming transition can safely try once more.
            s_applied_streaming = (int8_t)s_pending_streaming;
            s_conn_update_pending = false;
        }
        request_desired_connection_profile();
        return 0;
    }
    case BLE_GAP_EVENT_REPEAT_PAIRING: {
        struct ble_gap_conn_desc desc;
        if (ble_gap_conn_find(event->repeat_pairing.conn_handle, &desc) == 0) {
            ble_store_util_delete_peer(&desc.peer_id_addr);
        }
        return BLE_GAP_REPEAT_PAIRING_RETRY;
    }
    case BLE_GAP_EVENT_ENC_CHANGE:
        ESP_LOGI(TAG, "BLE encryption status: %d", event->enc_change.status);
        notify_pairing_passkey(0);
        if (event->enc_change.status == 0) request_desired_connection_profile();
        return 0;
    case BLE_GAP_EVENT_SUBSCRIBE:
        ESP_LOGI(TAG,
                 "BLE subscription: attr=%u notify=%u indicate=%u reason=%u",
                 event->subscribe.attr_handle,
                 event->subscribe.cur_notify,
                 event->subscribe.cur_indicate,
                 event->subscribe.reason);
        return 0;
    case BLE_GAP_EVENT_PASSKEY_ACTION: {
        struct ble_sm_io response = {0};
        int rc;

        response.action = event->passkey.params.action;
        switch (event->passkey.params.action) {
        case BLE_SM_IOACT_DISP:
        case BLE_SM_IOACT_INPUT:
            if (s_pairing_passkey == 0) {
                // A fresh six-digit code is generated for each pairing attempt.
                // Existing bonded reconnects never enter this path.
                notify_pairing_passkey(100000U + esp_random() % 900000U);
            }
            response.passkey = s_pairing_passkey;
            ESP_LOGI(TAG, "BLE pairing passkey displayed on device");
            break;
        case BLE_SM_IOACT_NUMCMP:
            // This display-only device has no explicit yes/no confirmation UI.
            // Reject an unexpected comparison request instead of silently
            // weakening pairing authentication.
            response.numcmp_accept = 0;
            ESP_LOGW(TAG, "BLE numeric comparison rejected: no confirmation UI");
            break;
        default:
            ESP_LOGW(TAG, "Unsupported BLE passkey action: %d",
                     event->passkey.params.action);
            return 0;
        }

        rc = ble_sm_inject_io(event->passkey.conn_handle, &response);
        if (rc != 0) ESP_LOGE(TAG, "BLE passkey response failed: %d", rc);
        return 0;
    }
    default:
        return 0;
    }
}

static int start_advertising(bool fast)
{
    static const ble_uuid16_t hid_uuid = BLE_UUID16_INIT(HID_SERVICE_UUID);
    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.appearance = ESP_HID_APPEARANCE_KEYBOARD;
    fields.appearance_is_present = 1;
    fields.tx_pwr_lvl = BLE_HS_ADV_TX_PWR_LVL_AUTO;
    fields.tx_pwr_lvl_is_present = 1;
    fields.name = (uint8_t *)DEVICE_NAME;
    fields.name_len = strlen(DEVICE_NAME);
    fields.name_is_complete = 1;
    fields.uuids16 = (ble_uuid16_t *)&hid_uuid;
    fields.num_uuids16 = 1;
    fields.uuids16_is_complete = 1;

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "Set advertising fields failed: %d", rc);
        return rc;
    }

    struct ble_gap_adv_params params = {0};
    params.conn_mode = BLE_GAP_CONN_MODE_UND;
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    params.itvl_min = BLE_GAP_ADV_ITVL_MS(fast ? ADV_FAST_MIN_MS : ADV_SLOW_MIN_MS);
    params.itvl_max = BLE_GAP_ADV_ITVL_MS(fast ? ADV_FAST_MAX_MS : ADV_SLOW_MAX_MS);
    int32_t duration_ms = fast ? ADV_FAST_DURATION_MS : BLE_HS_FOREVER;
    rc = ble_gap_adv_start(s_own_addr_type, NULL, duration_ms, &params,
                           gap_event, NULL);
    if (rc == BLE_HS_EALREADY) return 0;
    if (rc != 0) {
        ESP_LOGE(TAG, "Start advertising failed: %d", rc);
    } else {
        ESP_LOGI(TAG, "%s advertising: interval=%d-%dms duration=%ldms",
                 fast ? "Fast" : "Slow",
                 fast ? ADV_FAST_MIN_MS : ADV_SLOW_MIN_MS,
                 fast ? ADV_FAST_MAX_MS : ADV_SLOW_MAX_MS,
                 (long)duration_ms);
    }
    return rc;
}

static void hid_event(void *handler_arg, esp_event_base_t base, int32_t id,
                      void *event_data)
{
    (void)handler_arg;
    (void)base;
    esp_hidd_event_t event = (esp_hidd_event_t)id;
    esp_hidd_event_data_t *data = event_data;
    switch (event) {
    case ESP_HIDD_START_EVENT:
        {
            static const ble_uuid16_t hid_uuid = BLE_UUID16_INIT(0x1812);
            static const ble_uuid16_t scan_uuid = BLE_UUID16_INIT(0x1813);
            uint16_t hid_handle = 0;
            uint16_t scan_handle = 0;
            int hid_rc = ble_gatts_find_svc(&hid_uuid.u, &hid_handle);
            int scan_rc = ble_gatts_find_svc(&scan_uuid.u, &scan_handle);
            ESP_LOGI(TAG,
                     "GATT services: HID rc=%d handle=%u, Scan rc=%d handle=%u",
                     hid_rc, hid_handle, scan_rc, scan_handle);
            if (hid_rc == 0) {
                s_host_status_handle = find_host_status_handle(hid_handle);
                s_keyboard_input_handle = find_report_handle(
                    hid_handle, KEYBOARD_REPORT_ID, ESP_HID_REPORT_TYPE_INPUT);
                s_audio_input_handle = find_report_handle(
                    hid_handle, AUDIO_REPORT_ID, ESP_HID_REPORT_TYPE_INPUT);
                ESP_LOGI(TAG,
                         "HID report handles: host_status=%u keyboard=%u audio=%u",
                         s_host_status_handle, s_keyboard_input_handle,
                         s_audio_input_handle);
            }
        }
        if (configure_keyboard_identity() != 0) {
            ESP_LOGE(TAG, "Unable to configure BLE keyboard identity");
            return;
        }
        ESP_LOGI(TAG, "BLE HID ready; advertising as %s", DEVICE_NAME);
        start_advertising(true);
        break;
    case ESP_HIDD_CONNECT_EVENT:
        ESP_LOGI(TAG, "BLE HID connected");
        notify_connection(true);
        request_desired_connection_profile();
        break;
    case ESP_HIDD_DISCONNECT_EVENT:
        ESP_LOGI(TAG, "BLE HID disconnected: %d", data->disconnect.reason);
        notify_connection(false);
        break;
    case ESP_HIDD_OUTPUT_EVENT:
        if (data->output.report_id == HOST_STATUS_REPORT_ID)
            consume_host_output(data->output.data, data->output.length);
        break;
    default:
        break;
    }
}

static void host_task(void *arg)
{
    (void)arg;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

esp_err_t ble_keyboard_start(ble_keyboard_connection_cb_t connection_callback,
                             ble_keyboard_pairing_cb_t pairing_callback,
                             ble_keyboard_host_status_cb_t host_status_callback,
                             void *user)
{
    s_connection_cb = connection_callback;
    s_pairing_cb = pairing_callback;
    s_host_status_cb = host_status_callback;
    s_connection_user = user;

    esp_err_t err = nvs_flash_init();
    if (err != ESP_OK) {
        // Never erase provisioned NVS automatically on this device.
        ESP_LOGE(TAG, "NVS init failed (preserved, not erased): %s",
                 esp_err_to_name(err));
        return err;
    }
    load_keymap();

    err = esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT);
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return err;

    esp_bt_controller_config_t bt_cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    err = esp_bt_controller_init(&bt_cfg);
    if (err != ESP_OK) return err;
    err = esp_bt_controller_enable(ESP_BT_MODE_BLE);
    if (err != ESP_OK) return err;
    err = esp_nimble_init();
    if (err != ESP_OK) return err;

    // macOS treats keyboards as authenticated input devices. Use the same
    // display-only/passkey pairing model as ESP-IDF's NimBLE HID example.
    // macOS discovers the HID service first, then pairing is triggered when it
    // accesses the encrypted HID characteristics.
    ble_hs_cfg.sm_io_cap = BLE_HS_IO_DISPLAY_ONLY;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 1;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;

    err = esp_hidd_dev_init(&s_hid_config, ESP_HID_TRANSPORT_BLE, hid_event,
                            &s_hid_dev);
    if (err != ESP_OK) return err;
    ble_svc_gap_device_name_set(DEVICE_NAME);
    ble_svc_gap_device_appearance_set(ESP_HID_APPEARANCE_KEYBOARD);

    void ble_store_config_init(void);
    ble_store_config_init();

    s_control_tx_queue = xQueueCreate(CONTROL_TX_QUEUE_LENGTH,
                                      sizeof(tx_message_t));
    s_audio_tx_queue = xQueueCreate(AUDIO_TX_QUEUE_LENGTH,
                                    sizeof(tx_message_t));
    if (!s_control_tx_queue || !s_audio_tx_queue) return ESP_ERR_NO_MEM;
    if (xTaskCreate(tx_task, "ble_hid_tx", TX_TASK_STACK_SIZE, NULL,
                    TX_TASK_PRIORITY, &s_tx_task) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }

    err = esp_nimble_enable(host_task);
    if (err != ESP_OK) return err;
    return ESP_OK;
}

bool ble_keyboard_connected(void)
{
    return s_connected && s_hid_dev && esp_hidd_dev_connected(s_hid_dev);
}

void ble_keyboard_set_streaming(bool streaming)
{
    s_desired_streaming = streaming;
    request_desired_connection_profile();
}

void ble_keyboard_promote_advertising(void)
{
    if (s_conn_handle != BLE_HS_CONN_HANDLE_NONE || ble_keyboard_connected()) return;

    s_restart_fast_advertising = true;
    int rc = ble_gap_adv_stop();
    if (rc == BLE_HS_EALREADY) {
        s_restart_fast_advertising = false;
        start_advertising(true);
    } else if (rc != 0) {
        s_restart_fast_advertising = false;
        ESP_LOGW(TAG, "Unable to promote BLE advertising: %d", rc);
    }
}

void ble_keyboard_poll_host_status(void)
{
    if (!ble_keyboard_connected() || !s_host_status_handle) return;
    struct os_mbuf *om = NULL;
    if (ble_att_svr_read_local(s_host_status_handle, &om) != 0 || !om) return;
    uint8_t data[8] = {0};
    uint16_t length = 0;
    int rc = ble_hs_mbuf_to_flat(om, data, sizeof(data), &length);
    os_mbuf_free_chain(om);
    if (rc == 0) consume_host_output(data, length);
}

esp_err_t ble_keyboard_report(uint8_t modifiers, uint8_t key_code)
{
    if (!ble_keyboard_connected()) return ESP_ERR_INVALID_STATE;
    const tx_message_t message = {
        .kind = TX_KEYBOARD_REPORT,
        .length = 8,
        .data = {modifiers, 0, key_code, 0, 0, 0, 0, 0},
    };
    return queue_tx(&message, true);
}

esp_err_t ble_keyboard_tap(uint8_t key_code)
{
    return ble_keyboard_tap_chord(0, key_code);
}

esp_err_t ble_keyboard_tap_chord(uint8_t modifiers, uint8_t key_code)
{
    esp_err_t err = ble_keyboard_report(modifiers, key_code);
    if (err != ESP_OK) return err;
    vTaskDelay(pdMS_TO_TICKS(25));
    return ble_keyboard_report(0, 0);
}

static const shortcut_chord_t *shortcut_chord(shortcut_action_t action)
{
    if (action < 0 || action >= SHORTCUT_ACTION_COUNT) return NULL;
    return &s_keymap.action[action];
}

esp_err_t ble_keyboard_shortcut_press(shortcut_action_t action)
{
    const shortcut_chord_t *chord = shortcut_chord(action);
    return chord ? ble_keyboard_report(chord->modifiers, chord->key_code)
                 : ESP_ERR_INVALID_ARG;
}

esp_err_t ble_keyboard_shortcut_release(shortcut_action_t action)
{
    if (!shortcut_chord(action)) return ESP_ERR_INVALID_ARG;
    return ble_keyboard_report(0, 0);
}

esp_err_t ble_keyboard_shortcut_tap(shortcut_action_t action)
{
    const shortcut_chord_t *chord = shortcut_chord(action);
    return chord ? ble_keyboard_tap_chord(chord->modifiers, chord->key_code)
                 : ESP_ERR_INVALID_ARG;
}

static esp_err_t send_audio_packet(uint8_t type, uint16_t sequence,
                                   const uint8_t *payload, uint8_t payload_bytes)
{
    if (payload_bytes > AUDIO_PACKET_PAYLOAD_BYTES) return ESP_ERR_INVALID_SIZE;
    if (!ble_keyboard_connected()) return ESP_ERR_INVALID_STATE;

    tx_message_t message = {
        .kind = type == AUDIO_PACKET_START ? TX_AUDIO_START
                : type == AUDIO_PACKET_STOP ? TX_AUDIO_STOP
                                            : TX_AUDIO_PCM,
        .length = AUDIO_REPORT_BYTES,
    };
    message.data[0] = type;
    message.data[1] = (uint8_t)(sequence & 0xff);
    message.data[2] = (uint8_t)(sequence >> 8);
    message.data[3] = payload_bytes;
    if (payload_bytes) {
        memcpy(&message.data[AUDIO_PACKET_HEADER_BYTES], payload, payload_bytes);
    }
    return queue_tx(&message, type != AUDIO_PACKET_PCM);
}

esp_err_t ble_keyboard_audio_start(uint16_t sample_rate)
{
    uint8_t format[] = {
        1,
        (uint8_t)(sample_rate & 0xff),
        (uint8_t)(sample_rate >> 8),
        8,
        1,
    };
    s_audio_sequence = 0;
    s_audio_packets_queued = 0;
    s_audio_packets_dropped = 0;
    s_idle_profile_pending = false;
    xQueueReset(s_audio_tx_queue);
    s_desired_streaming = true;
    request_desired_connection_profile();
    return send_audio_packet(AUDIO_PACKET_START, 0, format, sizeof(format));
}

esp_err_t ble_keyboard_audio_write(const int8_t *pcm, size_t samples)
{
    if (!pcm && samples) return ESP_ERR_INVALID_ARG;
    const uint8_t *bytes = (const uint8_t *)pcm;
    size_t remaining = samples;
    while (remaining) {
        uint8_t chunk = remaining > AUDIO_PACKET_PAYLOAD_BYTES
                            ? AUDIO_PACKET_PAYLOAD_BYTES
                            : (uint8_t)remaining;
        esp_err_t err = send_audio_packet(AUDIO_PACKET_PCM,
                                          s_audio_sequence++, bytes, chunk);
        if (err != ESP_OK) return err;
        ++s_audio_packets_queued;
        bytes += chunk;
        remaining -= chunk;
    }
    return ESP_OK;
}

esp_err_t ble_keyboard_audio_stop(void)
{
    if (s_audio_tx_queue) xQueueReset(s_audio_tx_queue);
    return send_audio_packet(AUDIO_PACKET_STOP, s_audio_sequence, NULL, 0);
}
