set(AI_PASSPORT_PET_PLUGIN "none" CACHE STRING
    "Pet plugin: auto, none, or a directory under main/plugins/pets")
set(AI_PASSPORT_PROVIDER_PROFILE "generic" CACHE STRING
    "Provider display profile under main/plugins/providers")

set(provider_profile_dir
    "plugins/providers/${AI_PASSPORT_PROVIDER_PROFILE}")
if(NOT EXISTS
   "${CMAKE_CURRENT_LIST_DIR}/${provider_profile_dir}/provider_profile.h")
    message(FATAL_ERROR
        "Unknown AI_PASSPORT_PROVIDER_PROFILE=${AI_PASSPORT_PROVIDER_PROFILE}; "
        "expected ${provider_profile_dir}/provider_profile.h")
endif()
message(STATUS "AI Passport provider profile: ${AI_PASSPORT_PROVIDER_PROFILE}")

set(pet_plugin_sources "plugins/pets/pet_none.c")
if(AI_PASSPORT_PET_PLUGIN STREQUAL "auto")
    if(EXISTS "${CMAKE_CURRENT_LIST_DIR}/pet_local.c" AND
       EXISTS "${CMAKE_CURRENT_LIST_DIR}/pet_local.h")
        set(pet_plugin_sources
            "pet_local.c"
            "plugins/pets/pet_local_adapter.c")
        message(STATUS "AI Passport pet plugin: local pet")
    else()
        message(STATUS "AI Passport pet plugin: none")
    endif()
elseif(AI_PASSPORT_PET_PLUGIN STREQUAL "none")
    message(STATUS "AI Passport pet plugin: none")
else()
    set(custom_pet_source
        "plugins/pets/${AI_PASSPORT_PET_PLUGIN}/pet_plugin.c")
    if(NOT EXISTS "${CMAKE_CURRENT_LIST_DIR}/${custom_pet_source}")
        message(FATAL_ERROR
            "Unknown AI_PASSPORT_PET_PLUGIN=${AI_PASSPORT_PET_PLUGIN}; "
            "expected ${custom_pet_source}")
    endif()
    set(pet_plugin_sources "${custom_pet_source}")
    message(STATUS "AI Passport pet plugin: ${AI_PASSPORT_PET_PLUGIN}")
endif()

idf_component_register(
    SRCS "main.c"
         "ble_keyboard.c"
         ${pet_plugin_sources}
         "shortcut_app.c"
         "shortcut_keymap.c"
         "shortcut_protocol.c"
         "ui_pixel.c"
         "ui_pixel_math.c"
         "demo_display.c"
         "demo_button.c"
         "demo_audio.c"
         "demo_battery.c"
         "demo_radio.c"
         "demo_wifi.c"
         "demo_ble.c"
         "demo_low_power.c"
    INCLUDE_DIRS "." "plugins/pets" "${provider_profile_dir}"
    REQUIRES bsp bt esp_driver_usb_serial_jtag esp_event esp_hid esp_hw_support esp_netif esp_timer esp_wifi nvs_flash
)
