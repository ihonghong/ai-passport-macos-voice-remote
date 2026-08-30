#include "pet_plugin.h"

static const shortcut_pet_plugin_t s_plugin = {
    .id = "none",
    .frames = NULL,
    .frame_count = 0,
    .frame_ms = 0,
    .x = 0,
    .y = 0,
};

const shortcut_pet_plugin_t *shortcut_pet_plugin_get(void)
{
    return &s_plugin;
}
