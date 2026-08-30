#include "pet_plugin.h"
#include "pet_local.h"

static const shortcut_pet_plugin_t s_plugin = {
    .id = "local-pet",
    .frames = ui_pet_local_frames,
    .frame_count = UI_PET_LOCAL_FRAME_COUNT,
    .frame_ms = 280,
    .x = 13,
    .y = 240,
};

const shortcut_pet_plugin_t *shortcut_pet_plugin_get(void)
{
    return &s_plugin;
}
