<p align="right">
  <strong>简体中文</strong> · <a href="CI-build-and-release.md">English</a>
</p>

# 自动构建与发布（CI / Build & Release）

本仓库提供一套基于 GitHub Actions 的自动构建与发布流水线，用于在语义化版本 tag
上自动编译固件与通用 macOS App，并发布 Release。

本文件与 `.github/workflows/build-firmware.yml` 一同维护，工作流行为变化时必须同步更新。

## 触发条件

- **push tag**：当向仓库推送符合 `v*.*.*` 的 tag（如 `v0.1.0`、`v0.2.0`）时触发自动构建，并在构建成功后自动创建 Release。
- **workflow_dispatch**：可在 GitHub Actions 页面手动触发（用于调试/预发布验证）。

> 平时 push 到分支（非 tag）**不会**触发构建；只有打 tag 才会。

## 流水线做了什么

1. **ccache 缓存恢复**：使用 `actions/cache` 缓存编译中间产物（`.ccache`），二次编译大幅提速。缓存 key 含 ref 与 commit SHA；缓存保留时间以仓库的 GitHub Actions 设置为准。
2. **编译与验证**（ESP-IDF 5.5.3 / esp32c3）：运行与本地相同的 `./tools/validate.sh --firmware`。脚本使用 `sdkconfig.defaults` 和 `partitions.csv` 构建固件，再执行 `idf.py merge-bin`。
3. **验证完整固件**：脚本逐字节确认 bootloader、partition-table 和 app 位于 `0x0`、`0x8000` 和 `0x10000`，确认 `flash_args` 使用 8 MB Flash，并完整检查小程序 BLE 兼容契约，最后输出 `build/FoloToy-AI-Passport-full.bin`。
4. **构建 macOS App**：生成同时支持 `arm64` 和 `x86_64` 的原生 App。手动运行可以生成
   临时签名测试包；tag 构建必须完成 Developer ID 签名、Apple 公证、装订与 Gatekeeper
   校验，否则拒绝发布。
5. **上传 artifact**：每次成功构建都上传固件与 Mac App。普通分支只有从该分支手动运行
   `workflow_dispatch` 才会构建；普通 push 不触发。
6. **发布 tag**：tag 构建完成后，独立 release job 下载上述 artifact，生成 SHA-256
   校验文件与双语 Release 正文，再创建 GitHub Release。

构建 job 只有 `contents: read` 权限；仅 release job 在 tag 发布时获得 `contents: write`。所有 Action 均固定到完整 commit SHA，行尾注释保留对应发布版本，升级时需同时核对 SHA 与版本。

## Release 签名 Secrets

推送第一个 tag 前，需要配置以下 GitHub Actions Secrets：

- `MACOS_CERTIFICATE_BASE64`：经过 base64 编码的 Developer ID Application `.p12`。
- `MACOS_CERTIFICATE_PASSWORD`：该 `.p12` 的密码。
- `MACOS_SIGNING_IDENTITY`：完整的 Developer ID Application 身份名称。
- `APPLE_API_KEY_P8`：App Store Connect API 私钥内容。
- `APPLE_API_KEY_ID`：App Store Connect API Key ID。
- `APPLE_API_ISSUER_ID`：App Store Connect Issuer ID。

证书只导入 CI 临时钥匙串，并在 job 结束时删除。凭证与签名文件不得提交进仓库。

## Release 产物

成功的 tag Release 固定包含三个可下载产物：

- `FoloToy-AI-Passport-full.bin`：经过验证的 ESP32-C3 合并固件。
- `AI-Passport-macOS.zip`：经过签名与公证、已经内置 Bridge 的通用原生 App；不包含
  Python 或 BlackHole。
- `SHA256SUMS.txt`：固件与 App 压缩包的 SHA-256 校验值。

固件 CI 使用公开的 `none` 宠物和 `generic` Provider 显示配置，不包含私人素材或单台
设备数据。

## 安全安装 Release

合并产物 `FoloToy-AI-Passport-full.bin` 可用于两种不同的安装机制，不能把两者
当作相同操作：

- **已出厂配置设备的日常安装：**上电时按住上键 5 秒进入永久 Recovery，再用
  官方小程序安装合并产物。Recovery 会解析镜像，并保护每台设备的 `cardid`
  与永久 Recovery 分区。
- **本地开发：**使用分段 `idf.py flash`。它会按明确偏移写入 bootloader、分区表
  与主应用，不会用填充数据覆盖中间的运行 NVS。
- **明确的 USB 裸写恢复：**浏览器刷机工具或 `esptool` 从 `0x0` 写入合并文件时，
  会擦写文件范围内的全部扇区，包括被 `0xFF` 填充的 NVS 间隔，因此会重置蓝牙配对。
  它不应是默认升级路径。只有已校验文件在 `cardid` 之前结束，且用户接受重新
  配对时才使用；严禁裸写跨过 `cardid` 后续资源分区的合并产物。

浏览器可在本地写入和校验且不上传固件，但这不会让裸写具备 Recovery 的分区
保护语义。完整分区契约见 [BLE 与 Recovery 兼容性](ble-recovery-compatibility.zh_CN.md)。

## Release 标题

本仓库只发布一个受支持的产品。Tag 使用 `v0.1.0` 这样的语义化版本，workflow 将
Release 标题发布为 `v0.1.0 — AI Passport Mac Voice Remote`。无需在 tag 中重复应用名，
仓库名和 Release 标题已经表达产品身份。

## Release 说明

tag 触发的 Release 只有在 `docs/releases/<tag>.md` 与
`docs/releases/<tag>.zh_CN.md` 两份说明均存在时才会成功。工作流会把二者合并为 GitHub
Release 正文。请在推送 tag 前写完，并向可能没读过仓库的用户解释这次构建。覆盖三块：

- **功能（What's new / 功能）**：本次 Release 相对上一版新增或变更的功能、行为或修复。面向用户，
  不是 commit 日志。
- **方法（How to build / 方法）**：使用 `./tools/validate.sh --firmware` 生成并校验合并固件
  （不要以未校验的 `idf.py build` 代替），以及生成的 Recovery 兼容产物
  `FoloToy-AI-Passport-full.bin`。
- **使用（How to use / 使用）**：日常安装推荐永久 Recovery 与官方小程序，开发过程说明
  分段 `idf.py flash`，并把从 `0x0` 的 USB 裸写明确标记为会重置配对的恢复操作。

两种语言的 Release 说明应保持一致；用户可见行为同时与 `docs/CHANGELOG.md` 对齐。

## 相关文件

- `.github/workflows/build-firmware.yml`：本流水线定义。
- 详见 `docs/hardware-design/AI_HARDWARE_DEVELOPMENT_GUIDE.md`（硬件/烧录细节）。
