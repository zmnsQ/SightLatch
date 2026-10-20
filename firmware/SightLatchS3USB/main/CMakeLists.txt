idf_component_register(SRCS "main.c" "usb_link.c" "pairing_verifier.c"
  INCLUDE_DIRS "."
  REQUIRES esp_netif esp_event esp_timer esp_http_server protocomm protobuf-c nvs_flash json driver mbedtls bootloader_support)
