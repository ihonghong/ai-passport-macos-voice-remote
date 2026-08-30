<p align="right">
  <a href="README.zh_CN.md">简体中文</a> · <strong>English</strong>
</p>

# Pet Plugins

Pets are compile-time firmware plugins so clean builds do not require private
artwork or a runtime asset system. A plugin exports one descriptor containing
RGB565 LVGL frames, timing, and dashboard position.

Build without a pet:

```bash
idf.py -D AI_PASSPORT_PET_PLUGIN=none build
```

For a redistributable pet named `example`, add:

```text
main/plugins/pets/example/pet_plugin.c
```

The file implements `shortcut_pet_plugin_get()` from `pet_plugin.h`. Declare
each frame with `LV_IMAGE_DECLARE`, place pointers in a static array, and return
a `shortcut_pet_plugin_t`. Then build with:

```bash
idf.py -D AI_PASSPORT_PET_PLUGIN=example build
```

The optional `auto` mode recognizes the local, ignored
`main/pet_local.c` and `.h` files. This keeps the owner's current pet
working locally when explicitly selected without publishing artwork that lacks a redistribution license.
Public pet plugins must include the source and an explicit redistribution
license. Pre-convert animations to compact RGB565 frames; this ESP32-C3 has no
PSRAM and does not decode GIF files at runtime.
