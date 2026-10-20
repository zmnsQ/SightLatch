#pragma once
#include <stdbool.h>
#include "esp_err.h"

/* Call after esp_netif_init and the default event loop exist. STA only, no AP.
   apply/pause must run outside the parent's state lock and never in an event callback. */
esp_err_t wifi_link_init(void);
/* Accepts one asynchronous connection attempt, bounded to 15 seconds including DHCP.
   ESP_OK means attempt started, not connected. No automatic reconnection. */
esp_err_t wifi_link_apply(const char *ssid, const char *password);
/* ESP_OK confirms Wi-Fi stopped. Do NOT enable internal RNG entropy on an error. */
esp_err_t wifi_link_pause(void);
bool wifi_link_connected(void);
/* Static non-sensitive string; no SSID, password, IP address or driver error text. */
const char *wifi_link_state(void);
