#include "wifi_link.h"
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "mbedtls/platform_util.h"

/* All driver mutation is serialized, including the watchdog. Event handlers only
   update atomics / acknowledge a barrier, never call connect or block. */
enum link_state { LINK_UNINITIALIZED, LINK_PAUSED, LINK_CONNECTING,
                  LINK_CONNECTED, LINK_FAILED, LINK_TIMEOUT, LINK_STOP_ERROR };
static atomic_int s_state = LINK_UNINITIALIZED;
static atomic_bool s_accept_events;
static atomic_uint s_barrier_ack;
static unsigned s_barrier_epoch; /* protected by s_control */
static SemaphoreHandle_t s_control, s_barrier;
static esp_netif_t *s_sta;
static bool s_initialized, s_running;
static int64_t s_deadline; /* protected by s_control */
static esp_event_handler_instance_t s_wifi_handler, s_ip_handler, s_barrier_handler;
ESP_EVENT_DEFINE_BASE(SIGHTLATCH_WIFI_BARRIER);

static void on_barrier(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg; (void)base; (void)id;
    if (data) atomic_store(&s_barrier_ack, *(const unsigned *)data);
    xSemaphoreGive(s_barrier);
}

static void on_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    if (!atomic_load(&s_accept_events)) return;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        atomic_store(&s_state, LINK_FAILED); /* Deliberately no reconnect. */
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *event = data;
        if (event && event->esp_netif == s_sta) {
            int expected = LINK_CONNECTING;
            atomic_compare_exchange_strong(&s_state, &expected, LINK_CONNECTED);
        }
    } else if (base == IP_EVENT && id == IP_EVENT_STA_LOST_IP) {
        atomic_store(&s_state, LINK_FAILED);
    }
}

/* Caller holds s_control. Stop is authoritative, not disconnect's return value. */
static esp_err_t stop_locked(void)
{
    atomic_store(&s_accept_events, false);
    s_deadline = 0;
    if (s_running) {
        (void)esp_wifi_disconnect();
        esp_err_t err = esp_wifi_stop();
        if (err != ESP_OK && err != ESP_ERR_WIFI_NOT_STARTED) {
            atomic_store(&s_state, LINK_STOP_ERROR);
            return err; /* Do not claim RF off and do not allow entropy setup. */
        }
        // NOT_STARTED is documented as driver not started by esp_wifi_start.
        // This also recovers the conservative s_running flag after start fails.
        s_running = false;
    }
    /* Drain old STOP/disconnect/IP events before another attempt may accept them.
       Wi-Fi stop has already completed. This callback does no driver work. */
    (void)xSemaphoreTake(s_barrier, 0);
    unsigned epoch = ++s_barrier_epoch;
    esp_err_t err = esp_event_post(SIGHTLATCH_WIFI_BARRIER, 0, &epoch, sizeof(epoch), pdMS_TO_TICKS(1000));
    if (err != ESP_OK) { atomic_store(&s_state, LINK_STOP_ERROR); return err; }
    TickType_t started = xTaskGetTickCount();
    while (atomic_load(&s_barrier_ack) != epoch) {
        TickType_t elapsed = xTaskGetTickCount() - started;
        if (elapsed >= pdMS_TO_TICKS(1000) ||
            xSemaphoreTake(s_barrier, pdMS_TO_TICKS(1000) - elapsed) != pdTRUE) {
            atomic_store(&s_state, LINK_STOP_ERROR);
            return ESP_ERR_TIMEOUT;
        }
    }
    atomic_store(&s_state, LINK_PAUSED);
    return ESP_OK;
}

static void watchdog(void *arg)
{
    (void)arg;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(100));
        if (xSemaphoreTake(s_control, pdMS_TO_TICKS(50)) != pdTRUE) continue;
        int state = atomic_load(&s_state);
        bool expired = state == LINK_CONNECTING && s_deadline && esp_timer_get_time() >= s_deadline;
        if (s_running && (expired || state == LINK_FAILED)) {
            esp_err_t err = stop_locked();
            if (err == ESP_OK) atomic_store(&s_state, expired ? LINK_TIMEOUT : LINK_FAILED);
        }
        xSemaphoreGive(s_control);
    }
}

esp_err_t wifi_link_init(void)
{
    if (s_initialized || s_control) return ESP_ERR_INVALID_STATE;
    s_control = xSemaphoreCreateMutex();
    s_barrier = xSemaphoreCreateBinary();
    if (!s_control || !s_barrier) return ESP_ERR_NO_MEM;
    s_sta = esp_netif_create_default_wifi_sta();
    if (!s_sta) return ESP_ERR_NO_MEM;
    wifi_init_config_t config = WIFI_INIT_CONFIG_DEFAULT();
    config.nvs_enable = 0; /* Only parent's atomic NVS JSON persists credentials. */
    esp_err_t err = esp_wifi_init(&config);
    if (err != ESP_OK) return err;
    err = esp_wifi_set_storage(WIFI_STORAGE_RAM);
    if (err != ESP_OK) return err;
    err = esp_wifi_set_mode(WIFI_MODE_STA);
    if (err != ESP_OK) return err;
    err = esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, on_event, NULL, &s_wifi_handler);
    if (err != ESP_OK) return err;
    err = esp_event_handler_instance_register(IP_EVENT, ESP_EVENT_ANY_ID, on_event, NULL, &s_ip_handler);
    if (err != ESP_OK) return err;
    err = esp_event_handler_instance_register(SIGHTLATCH_WIFI_BARRIER, 0, on_barrier, NULL, &s_barrier_handler);
    if (err != ESP_OK) return err;
    if (xTaskCreate(watchdog, "sl_wifi_guard", 3072, NULL, 4, NULL) != pdPASS) return ESP_ERR_NO_MEM;
    s_initialized = true;
    atomic_store(&s_state, LINK_PAUSED);
    return ESP_OK; /* No RF start here. */
}

esp_err_t wifi_link_pause(void)
{
    if (!s_initialized) return ESP_ERR_INVALID_STATE;
    if (xSemaphoreTake(s_control, pdMS_TO_TICKS(3000)) != pdTRUE) return ESP_ERR_TIMEOUT;
    esp_err_t err = stop_locked();
    xSemaphoreGive(s_control);
    return err;
}

esp_err_t wifi_link_apply(const char *ssid, const char *password)
{
    if (!s_initialized) return ESP_ERR_INVALID_STATE;
    if (!ssid || !password) return ESP_ERR_INVALID_ARG;
    size_t ns = strnlen(ssid, 33), np = strnlen(password, 64);
    if (ns < 1 || ns > 32 || (np && (np < 8 || np > 63))) return ESP_ERR_INVALID_ARG;
    for (size_t i = 0; i < np; ++i) {
        if ((unsigned char)password[i] < 32 || (unsigned char)password[i] > 126) return ESP_ERR_INVALID_ARG;
    }
    if (xSemaphoreTake(s_control, pdMS_TO_TICKS(3000)) != pdTRUE) return ESP_ERR_TIMEOUT;
    esp_err_t err = stop_locked();
    if (err != ESP_OK) { xSemaphoreGive(s_control); return err; }
    wifi_config_t config = {0};
    memcpy(config.sta.ssid, ssid, ns); /* 32-byte SSID need not have NUL terminator. */
    memcpy(config.sta.password, password, np);
    config.sta.scan_method = WIFI_ALL_CHANNEL_SCAN;
    config.sta.failure_retry_cnt = 0;
    config.sta.threshold.authmode = np ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;
    config.sta.pmf_cfg.capable = true;
    config.sta.pmf_cfg.required = false;
    err = esp_wifi_set_config(WIFI_IF_STA, &config);
    mbedtls_platform_zeroize(&config, sizeof(config));
    if (err == ESP_OK) {
        s_running = true; /* Conservatively require a confirmed stop even if start fails. */
        atomic_store(&s_state, LINK_CONNECTING);
        atomic_store(&s_accept_events, true);
        s_deadline = esp_timer_get_time() + 15000000;
        err = esp_wifi_start();
        if (err == ESP_OK) err = esp_wifi_connect(); /* Exactly one call; never in callbacks. */
    }
    if (err != ESP_OK) {
        esp_err_t stopped = stop_locked();
        if (stopped == ESP_OK) atomic_store(&s_state, LINK_FAILED);
        else err = stopped;
    }
    xSemaphoreGive(s_control);
    return err;
}

bool wifi_link_connected(void)
{
    return atomic_load(&s_state) == LINK_CONNECTED;
}

const char *wifi_link_state(void)
{
    switch (atomic_load(&s_state)) {
    case LINK_PAUSED: return "paused";
    case LINK_CONNECTING: return "connecting";
    case LINK_CONNECTED: return "connected";
    case LINK_FAILED: return "failed";
    case LINK_TIMEOUT: return "timeout";
    case LINK_STOP_ERROR: return "stop_error";
    default: return "uninitialized";
    }
}
