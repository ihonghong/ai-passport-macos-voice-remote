<p align="right">
  <strong>简体中文</strong> · <a href="README.md">English</a>
</p>

# 宠物插件

宠物是编译期固件插件，因此干净构建不依赖私人素材，也不需要运行时资源系统。一个插件
只需导出包含 RGB565 LVGL 帧、动画间隔和仪表盘位置的描述对象。

不带宠物构建：

```bash
idf.py -D AI_PASSPORT_PET_PLUGIN=none build
```

要加入名为 `example` 且允许再分发的宠物，请添加：

```text
main/plugins/pets/example/pet_plugin.c
```

该文件实现 `pet_plugin.h` 中的 `shortcut_pet_plugin_get()`。使用
`LV_IMAGE_DECLARE` 声明每帧，把指针放入静态数组，并返回
`shortcut_pet_plugin_t`。随后构建：

```bash
idf.py -D AI_PASSPORT_PET_PLUGIN=example build
```

可选的 `auto` 模式会识别本地且已忽略的 `main/pet_local.c` 和 `.h`。明确选择
后，所有者的宠物仍可在本机使用，同时不会发布缺少再分发许可的素材。公开宠物插件必须
提供来源和明确的再分发许可证。动画应预先转换为紧凑的 RGB565 帧；ESP32-C3 没有
PSRAM，固件也不会在运行时解码 GIF。
