#pragma once

#include "lvgl.h"

#include <stddef.h>
#include <stdint.h>

typedef struct {
    const char *id;
    const lv_image_dsc_t *const *frames;
    size_t frame_count;
    uint16_t frame_ms;
    int16_t x;
    int16_t y;
} shortcut_pet_plugin_t;

// Exactly one compile-time pet plugin exports this function.
const shortcut_pet_plugin_t *shortcut_pet_plugin_get(void);
