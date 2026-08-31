<p align="right">
  <strong>简体中文</strong> · <a href="README.md">English</a>
</p>

# 图片资源（Images）

本目录存放项目可复用的图片资源，如 UI 图标、背景、RGB565 资源等。

## 如何使用

- 图片文件复制到本目录，并在本项目 `README.md` 记录分辨率、格式、用途与来源。
- 与固件集成时，参考 [`components/bsp/include/bsp_display.h`](../../components/bsp/include/bsp_display.h) 与相关示例分支的图片资源管线，转换为固件所需格式（如 RGB565 数组）。
- 图片资源占用 Flash 与内存，集成前请评估 ESP32-C3 无 PSRAM 的限制。

## 目录说明

> 加入资源时请同步更新本 `README.md` 的索引。

## README 渲染图

- `voice-remote-ready.png`：720 × 960，展示已连接并处于 Ready 的界面。
- `voice-remote-listening.png`：720 × 960，展示正在传输麦克风音频时的波形与计时。

两张图片都是固件 240 × 320 布局的 3 倍确定性渲染。图中的通用宠物专为本项目生成，
不包含所有者本地宠物素材或名字。

## 本地可选资源

- `local-pet-idle-clean.gif`：由用户的 Codex 宠物形象适配而来的 192 × 208、
  6 帧待机动画，用于 AI Passport 仪表盘。固件使用本地预生成的 68 × 74 RGB565 帧，
  不启用 GIF 解码器。由于没有独立的再分发许可证，GIF 和生成的 C 文件已被忽略；
  `auto` 宠物选择仍让所有者在本机继续使用，但公开克隆不会包含这些文件。详见
  [`main/plugins/pets/README.zh_CN.md`](../../main/plugins/pets/README.zh_CN.md)。
