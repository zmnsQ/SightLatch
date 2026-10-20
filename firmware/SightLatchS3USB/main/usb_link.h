#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

/* Call init once from app_main. HID calls belong to the safety task, not callbacks. */
esp_err_t usb_link_init(void);
bool usb_link_ready(void);
bool usb_link_mouse(uint8_t buttons, int8_t dx, int8_t dy, int8_t wheel);
bool usb_link_keyboard(uint8_t key, uint8_t modifiers);
/* Best effort, bounded 100 ms total; disconnected/suspended hosts cannot receive. */
bool usb_link_release(void);
