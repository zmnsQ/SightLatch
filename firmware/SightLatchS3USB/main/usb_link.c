#include "usb_link.h"
#include "sdkconfig.h"
#if !CONFIG_IDF_TARGET_ESP32S3
#error "SightLatch USB NCM + HID requires ESP32-S3 USB OTG (not C3 Serial/JTAG)"
#endif
#if !CONFIG_TINYUSB_NET_MODE_NCM || CONFIG_TINYUSB_HID_COUNT != 1
#error "Enable NCM and exactly one HID interface"
#endif
#if CONFIG_TINYUSB_CDC_ENABLED || CONFIG_TINYUSB_MSC_ENABLED || CONFIG_TINYUSB_MTP_ENABLED
#error "This custom descriptor requires CDC, MSC and MTP disabled (MAC string index 5)"
#endif
#include <stdlib.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "tinyusb.h"
#include "tinyusb_default_config.h"
#include "tinyusb_net.h"

#define REPORT_KEYBOARD 1
#define REPORT_MOUSE 2
#define CONFIGURATION_LENGTH (TUD_CONFIG_DESC_LEN + TUD_CDC_NCM_DESC_LEN + TUD_HID_DESC_LEN)

static esp_netif_t *s_netif;
static SemaphoreHandle_t s_hid_lock;
static SemaphoreHandle_t s_tx_lock;
static atomic_bool s_initialized;
static char s_serial[13];
static const uint8_t s_hid_report[] = {
    TUD_HID_REPORT_DESC_KEYBOARD(HID_REPORT_ID(REPORT_KEYBOARD)),
    TUD_HID_REPORT_DESC_MOUSE(HID_REPORT_ID(REPORT_MOUSE))
};
static const tusb_desc_device_t s_device = {
    .bLength = sizeof(tusb_desc_device_t), .bDescriptorType = TUSB_DESC_DEVICE,
    .bcdUSB = 0x0200, .bDeviceClass = TUSB_CLASS_MISC,
    .bDeviceSubClass = MISC_SUBCLASS_COMMON, .bDeviceProtocol = MISC_PROTOCOL_IAD,
    .bMaxPacketSize0 = CFG_TUD_ENDPOINT0_SIZE,
    /* Espressif VID is for prototype development only, not product assignment. */
    .idVendor = 0x303a, .idProduct = 0x4004, .bcdDevice = 0x0100,
    .iManufacturer = 1, .iProduct = 2, .iSerialNumber = 3, .bNumConfigurations = 1
};
static const uint8_t s_configuration[] = {
    TUD_CONFIG_DESCRIPTOR(1, 3, 0, CONFIGURATION_LENGTH, 0, 100),
    TUD_CDC_NCM_DESCRIPTOR(0, 4, 5, 0x81, 64, 0x02, 0x82, 64, CFG_TUD_NET_MTU),
    TUD_HID_DESCRIPTOR(2, 6, HID_ITF_PROTOCOL_NONE, sizeof(s_hid_report), 0x83, 16, 1)
};
_Static_assert(sizeof(s_configuration) == CONFIGURATION_LENGTH, "USB descriptor length");
/* esp_tinyusb 2.4.0 tinyusb_net_init writes index 5 when CDC/MSC are disabled. */
static const char *s_strings[] = {
    (const char[]){0x09, 0x04}, "SightLatch", "SightLatch S3 USB",
    s_serial, "SightLatch local link", "", "SightLatch keyboard and mouse"
};

bool usb_link_ready(void)
{
    return atomic_load(&s_initialized) && tud_mounted() && !tud_suspended();
}

static void free_rx(void *handle, void *buffer)
{
    (void)handle;
    free(buffer);
}

static esp_err_t receive_frame(void *buffer, uint16_t len, void *ctx)
{
    if (!buffer || len < 14 || len > CFG_TUD_NET_MTU || !usb_link_ready()) {
        return ESP_ERR_INVALID_STATE;
    }
    void *copy = malloc(len);
    if (!copy) return ESP_ERR_NO_MEM;
    memcpy(copy, buffer, len);
    /* ETH input consumes the allocation on success AND failure (IDF 5.5).
       Do not free again on an error return. TinyUSB renews its source on return. */
    return esp_netif_receive((esp_netif_t *)ctx, copy, len, NULL);
}

static esp_err_t transmit_frame(void *handle, void *buffer, size_t len)
{
    (void)handle;
    if (!usb_link_ready() || len > UINT16_MAX) return ESP_ERR_INVALID_STATE;
    if (xSemaphoreTake(s_tx_lock, pdMS_TO_TICKS(100)) != pdTRUE) return ESP_ERR_TIMEOUT;
    /* Synchronous API copies in tud_network_xmit_cb before signaling completion.
       On timeout it cancels packet_to_send under its semaphore, so this borrowed
       lwIP buffer may be released after return. No free_tx_buffer callback here.
       Never call this from TinyUSB callbacks. The mutex serializes sync sends. */
    esp_err_t err = tinyusb_net_send_sync(buffer, (uint16_t)len, NULL, pdMS_TO_TICKS(100));
    xSemaphoreGive(s_tx_lock);
    return err;
}

static esp_err_t create_network(const uint8_t mac[6])
{
    esp_err_t err = esp_netif_init();
    if (err != ESP_OK) return err;
    esp_netif_ip_info_t ip = {0};
    ESP_IP4_ADDR(&ip.ip, 192, 168, 7, 1);
    ESP_IP4_ADDR(&ip.netmask, 255, 255, 255, 0);
    esp_netif_inherent_config_t base = {
        .flags = ESP_NETIF_DHCP_SERVER | ESP_NETIF_FLAG_AUTOUP,
        .ip_info = &ip, .if_key = "USB_NCM", .if_desc = "usb",
        .route_prio = 10
    };
    memcpy(base.mac, mac, 6);
    esp_netif_driver_ifconfig_t driver = {
        .handle = &s_netif, .transmit = transmit_frame, .driver_free_rx_buffer = free_rx
    };
    esp_netif_config_t cfg = {
        .base = &base, .driver = &driver, .stack = ESP_NETIF_NETSTACK_DEFAULT_ETH
    };
    s_netif = esp_netif_new(&cfg);
    if (!s_netif) return ESP_ERR_NO_MEM;
    uint8_t offer = 0;
    err = esp_netif_dhcps_option(s_netif, ESP_NETIF_OP_SET,
        ESP_NETIF_ROUTER_SOLICITATION_ADDRESS, &offer, sizeof(offer));
    if (err != ESP_OK) return err;
    err = esp_netif_dhcps_option(s_netif, ESP_NETIF_OP_SET,
        ESP_NETIF_DOMAIN_NAME_SERVER, &offer, sizeof(offer));
    if (err != ESP_OK) return err;
    /* Network stays locally up; no synchronous lwIP IPC from USB callbacks.
       DHCP has no gateway/DNS offer: this is not an Internet router. */
    esp_netif_action_start(s_netif, NULL, 0, NULL);
    esp_netif_dhcp_status_t status;
    err = esp_netif_dhcps_get_status(s_netif, &status);
    if (err != ESP_OK) return err;
    return esp_netif_is_netif_up(s_netif) && status == ESP_NETIF_DHCP_STARTED
        ? ESP_OK : ESP_FAIL;
}

esp_err_t usb_link_init(void)
{
    if (atomic_load(&s_initialized) || s_hid_lock) return ESP_ERR_INVALID_STATE;
    s_hid_lock = xSemaphoreCreateMutex();
    s_tx_lock = xSemaphoreCreateMutex();
    if (!s_hid_lock || !s_tx_lock) return ESP_ERR_NO_MEM;
    uint8_t mac[6], host_mac[6];
    esp_err_t err = esp_read_mac(mac, ESP_MAC_BASE);
    if (err != ESP_OK) return err;
    snprintf(s_serial, sizeof(s_serial), "%02X%02X%02X%02X%02X%02X",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    mac[0] = (mac[0] | 0x02) & 0xfe; /* locally administered, unicast */
    memcpy(host_mac, mac, sizeof(mac));
    host_mac[5] ^= 0x01; /* Host NIC and board IP stack must have distinct MACs. */
    err = create_network(mac);
    if (err != ESP_OK) return err;
    tinyusb_config_t config = TINYUSB_DEFAULT_CONFIG();
    config.descriptor.device = &s_device;
    config.descriptor.full_speed_config = s_configuration;
    config.descriptor.string = s_strings;
    config.descriptor.string_count = sizeof(s_strings) / sizeof(s_strings[0]);
    err = tinyusb_driver_install(&config);
    if (err != ESP_OK) return err;
    tinyusb_net_config_t net = {
        .on_recv_callback = receive_frame, .user_context = s_netif
    };
    memcpy(net.mac_addr, host_mac, sizeof(host_mac));
    err = tinyusb_net_init(&net);
    if (err != ESP_OK) return err;
    atomic_store(&s_initialized, true);
    return ESP_OK;
}

bool usb_link_mouse(uint8_t buttons, int8_t dx, int8_t dy, int8_t wheel)
{
    if (!usb_link_ready() || xSemaphoreTake(s_hid_lock, 0) != pdTRUE) return false;
    bool sent = usb_link_ready() && tud_hid_ready() &&
        tud_hid_mouse_report(REPORT_MOUSE, buttons & 0x07, dx, dy, wheel, 0);
    xSemaphoreGive(s_hid_lock);
    return sent;
}

bool usb_link_keyboard(uint8_t key, uint8_t modifiers)
{
    if (!usb_link_ready() || xSemaphoreTake(s_hid_lock, 0) != pdTRUE) return false;
    uint8_t keys[6] = {key, 0, 0, 0, 0, 0};
    bool sent = usb_link_ready() && tud_hid_ready() &&
        tud_hid_keyboard_report(REPORT_KEYBOARD, modifiers, keys);
    xSemaphoreGive(s_hid_lock);
    return sent;
}

bool usb_link_release(void)
{
    if (!usb_link_ready()) return false;
    /* Two reports share one endpoint. Wait for room, never from a USB callback. */
    TickType_t start = xTaskGetTickCount();
    bool keyboard = false, mouse = false;
    do {
        if (!usb_link_ready()) break;
        if (!keyboard) keyboard = usb_link_keyboard(0, 0);
        else if (!mouse) mouse = usb_link_mouse(0, 0, 0, 0);
        if (keyboard && mouse) break;
        vTaskDelay(1);
    } while ((xTaskGetTickCount() - start) < pdMS_TO_TICKS(100));
    return keyboard && mouse;
}

uint8_t const *tud_hid_descriptor_report_cb(uint8_t instance)
{
    return instance == 0 ? s_hid_report : NULL;
}

uint16_t tud_hid_get_report_cb(uint8_t instance, uint8_t report_id,
    hid_report_type_t report_type, uint8_t *buffer, uint16_t reqlen)
{
    (void)instance; (void)report_id; (void)report_type; (void)buffer; (void)reqlen;
    return 0; /* No cached input state; unsupported GET_REPORT is stalled. */
}

void tud_hid_set_report_cb(uint8_t instance, uint8_t report_id,
    hid_report_type_t report_type, uint8_t const *buffer, uint16_t bufsize)
{
    /* Keyboard LED output has no control authority. Never block this callback. */
    (void)instance; (void)report_id; (void)report_type; (void)buffer; (void)bufsize;
}
