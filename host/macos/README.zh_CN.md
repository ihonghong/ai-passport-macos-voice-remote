<p align="right">
  <strong>简体中文</strong> · <a href="README.md">English</a>
</p>

# macOS 主机端

macOS 主机端把 AI Passport 变成无线按住说话遥控器和听写麦克风。原生菜单栏 App
已经内置 BLE HID Bridge、PCM 转换、Core Audio 输出、输入设备策略、快捷键配置与
可选用量指标；运行时不再依赖 Python。

## Mac 上运行什么

```text
AI Passport BLE HID
  ├─ 键盘报告 ───────────────────────> macOS 快捷键 / 回车 / Command-Delete
  ├─ 麦克风报告 -> 原生 App ─────────> BlackHole 2ch -> 听写应用
  └─ 状态报告 <--- 原生 App ────────── 剩余额度、今日 Token、日期时间、音频状态
```

设备只需作为一个 Bluetooth HID 设备配对。一个原生 Swift 进程通过 IOKit 接收音频
报告，并通过 Core Audio 输出转换后的 48 kHz 双声道 PCM。BlackHole 仍是唯一外部
运行依赖，因为普通 App 不能自行注册成系统麦克风驱动。菜单栏 App 还负责显示状态，
并在 AI Passport 输入和上一次物理麦克风之间切换。

## 环境要求

- 支持 Bluetooth LE 的 macOS
- BlackHole 2ch（Homebrew 是一种安装方式）
- 已运行本仓库快捷键固件的 AI Passport

Release 中的通用 App 同时支持 Apple 芯片和 Intel Mac。只有从源码构建时才需要
Xcode Command Line Tools。

## 安装

普通用户可从 Release 下载 `AI-Passport-macOS.zip`，把 `AI Passport.app` 移入
“应用程序”后打开。CI 生成的临时签名版本可能需要在访达中右键选择“打开”；若希望
下载后完全没有 Gatekeeper 提示，Release 还需要 Developer ID 签名和 Apple 公证。

从源码构建安装时运行：

```bash
./host/macos/install.sh --dry-run
./host/macos/install.sh --yes
```

如果本次刚安装 BlackHole，请重启 macOS 后再次运行安装器。随后打开
**系统设置 > 蓝牙**，连接 **AI Passport**，再验证：

```bash
./host/macos/doctor.sh
```

安装器只创建当前用户拥有的文件：

- `~/Library/Application Support/AI Passport Bridge/`
- `~/Applications/AI Passport.app`

升级时会保留已有 `config.json`，停用旧的 Python／LaunchAgent 运行方式，并由 App
注册 macOS 登录项；不会刷写设备、清除蓝牙配对或卸载 BlackHole。

## 配置语音快捷键

**使用语音键输入文字前，用户必须手动完成这一步。**公开固件会被识别为键盘；按住
语音键时，它默认持续发送**左 Control + 左 Command**。这是 AI Passport 项目的默认值，
不是 macOS、系统听写或任意输入法都通用的默认快捷键。每位用户都需要在自己选择的
听写应用或输入法中，把全局语音触发快捷键设为完全相同的组合。主机安装器不会自动
安装或配置豆包、macOS 听写或其他输入法。

绑定后，从菜单栏选择“AI Passport 输入”，聚焦一个文本框，按住 Passport 语音键说话，
然后松开。如果所用应用有独立的麦克风选择项，也要在其中选择 `BlackHole 2ch`。发送键
输出回车，清除键输出 Command-Delete。

“AI Passport 输入”会在 Bridge 与设备正常连接期间持续使用 `BlackHole 2ch`。如果
Bridge 停止、报错或等待设备，状态栏应用会临时恢复上一次物理麦克风，避免系统停留在
没有音频的虚拟输入；设备重新连接后会自动恢复 Passport 输入。手动选择“会议输入
（物理麦克风）”会取消自动恢复，直到再次选择“AI Passport 输入”。

## 配置

从菜单栏选择“打开配置文件”，编辑后再选择“重新启动音频桥”。文件位于
`~/Library/Application Support/AI Passport Bridge/config.json`：

```json
{
  "device_name": "AI Passport",
  "audio_device": "BlackHole 2ch",
  "shortcuts": {
    "voice": { "modifiers": ["left_control", "left_command"], "key": null },
    "send": { "modifiers": [], "key": "return" },
    "clear": { "modifiers": ["left_command"], "key": "delete" }
  },
  "provider": {
    "name": "none",
    "settings": { "refresh_seconds": 300 }
  }
}
```

Bridge 连接后会通过现有 HID Output Report 一次发送完整快捷键映射。固件校验 checksum
后，仅在映射变化时写入 NVS；相同配置不会重复写 Flash。该机制不改变 HID 描述，也不
要求重新配对。可用修饰键名称包括 `left_control`、`left_shift`、`left_option`、
`left_command` 以及对应的 `right_` 名称；具名按键包括 `return`、`escape`、`delete`、
`space`，也可以填写 `0` 至 `101` 的 USB HID usage 整数。每个动作至少需要一个修饰键
或普通键。编辑后重新启动 Bridge，并把听写应用设置为相同的语音组合键。

指标默认关闭。需要时可把 `provider.name` 改为 `codex` 或 `auto`。原生 Codex
Provider 会通过本地 Codex CLI 读取额度，并从本机 `~/.codex` 会话记录读取 Token
计数事件；这些记录不会上传。Provider 只定期轮询，不会额外维持一条蓝牙连接；状态
数据复用现有 HID 连接发送。旧 Python Bridge 仍保留在仓库中，仅作为诊断与迁移参考；安装后的
App 不会加载它。

仅在对比排障时手动运行旧 Bridge：

```bash
python3 host/macos/bridge/mac_shortcut_bridge.py --self-test
python3 host/macos/bridge/mac_shortcut_bridge.py --print-effective-config
```

## 固件与配对安全

使用 ESP-IDF 5.5.3。对已经出厂配置的设备，开发时使用分段 `idf.py flash`；
日常安装 Release 时使用永久 Recovery 和官方小程序。严禁运行 `idf.py erase-flash`，
它会破坏每台设备的身份与永久 Recovery。也不要把从 `0x0` 裸写合并镜像当作
日常升级：镜像的 `0xFF` 间隔会覆盖运行 NVS 并重置蓝牙配对，未来含资源分区的产物
还可能跨过后续保护区域。详见 [BLE 与 Recovery 兼容性](../../docs/development/ble-recovery-compatibility.zh_CN.md)。

改变 BLE 安全配置后，可能需要在 macOS 蓝牙设置中删除旧设备再重新配对。正常升级
主机端不会重置配对。

需要建立新 bond 时，固件会生成新的 6 位配对码并显示在 Passport 屏幕上，请在
macOS 蓝牙提示框中输入该数字。加密成功或连接断开后配对码自动隐藏；已有 bond 的
正常重连不会再次显示配对码。

## 卸载

```bash
./host/macos/uninstall.sh
```

该命令注销登录项并移除原生 App 和本地配置，但保留 BlackHole、蓝牙配对和设备固件。

## 让 Agent 直接安装

可以把下面这段话交给安装 Agent：

```text
阅读 AGENTS.md 和 host/macos/README.zh_CN.md，保留已有改动和正在运行的服务。
先运行 host/macos/install.sh --dry-run，确认路径后运行
host/macos/install.sh --yes 和 host/macos/doctor.sh。严禁擦除 Flash。日常安装 Release 使用
永久 Recovery 和官方小程序；开发时使用 ESP-IDF 5.5.3 和分段 idf.py flash。
除非用户明确要求 USB 恢复并接受重新配对，否则不得在 0x0 裸写合并固件。
蓝牙配对留给用户在系统设置中完成，分别报告主机检查和真机检查。
提醒用户把听写应用或输入法的语音快捷键绑定为左 Control + 左 Command；未经允许，
不要替用户配置输入法。
```

Agent 可以非交互完成全部主机文件安装，但 macOS 仍可能要求用户批准蓝牙配对，并在
首次安装 BlackHole 后重启。

## 故障排查

- 蓝牙页没有连接按钮：删除残留的 AI Passport 条目、重启设备，再从系统设置配对，
  不要从 Bridge 内尝试配对。
- 键盘可用但语音仍走 Mac 麦克风：在菜单栏选择“AI Passport 输入”，并确认听写应用
  跟随系统输入设备。
- 语音键没有反应：把听写应用或输入法的全局语音快捷键绑定为**左 Control + 左
  Command**。
- 设备显示 `BRIDGE OFF`：运行 `doctor.sh`，查看
  `~/Library/Logs/AI Passport Bridge.log`，再重启音频桥。
- 开会时收到 Passport 音频：入会前选择“会议输入（物理麦克风）”。
- Passport 断开后仍显示 BlackHole：确认状态栏应用正在运行；它会在下一次状态刷新时
  恢复上一次物理麦克风。
