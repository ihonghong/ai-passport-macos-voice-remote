<p align="right">
  <a href="README.md">English</a> · <strong>简体中文</strong>
</p>

# AI Passport Mac 语音遥控器

这个 fork 把 FoloToy AI Passport 变成一块无线 macOS 语音输入遥控器：

- 按住实体键触发听写，并流式传输开发板麦克风音频；
- 另外两个按键发送回车或 Command-Delete；
- 屏幕显示日期时间、电量、连接状态、可选 AI 用量和可选宠物；
- 键盘与 8 kHz 单声道麦克风共用一次加密 BLE HID 配对。

仓库同时包含 ESP32-C3 固件，以及已经内置 Bridge 的原生 macOS 菜单栏 App。指标来源与屏幕宠物
都是可替换的可选插件；公开克隆不依赖 Codex，也不依赖私人素材。
仓库保留原始 [FoloToy AI Passport](https://github.com/FoloToy/ai-passport) 历史与 MIT
署名，并独立维护当前产品版本。

## 界面状态

<table>
  <tr>
    <td align="center"><img src="assets/images/voice-remote-ready.png" alt="AI Passport 已连接并就绪" width="320"></td>
    <td align="center"><img src="assets/images/voice-remote-listening.png" alt="AI Passport 正在倾听并传输麦克风音频" width="320"></td>
  </tr>
  <tr>
    <td align="center"><strong>已连接 / Ready</strong></td>
    <td align="center"><strong>Listening</strong></td>
  </tr>
</table>

图中的用量指标和宠物均为可选插件示例；公开默认构建不依赖它们。

## 安装固件

从 GitHub Release 下载 `FoloToy-AI-Passport-full.bin`。对已完成出厂配置的
AI Passport，请使用永久 Recovery 和官方小程序安装：上电时按住上键
5 秒进入 Recovery，再安装 Release 产物。Recovery 会解析合并镜像，并保护
每台设备的 `cardid` 与永久 Recovery 分区。

开发者也可使用分段 `idf.py flash`。不要把浏览器或 `esptool` 从 `0x0`
裸写合并镜像当作日常升级方式：镜像在 NVS 区域的填充会覆盖运行数据，
并重置蓝牙配对。只有在明确进行 USB 恢复、产物已校验为在 `cardid` 前结束，
且用户接受重新配对时，才使用该路径。详见 [固件安装与 Recovery 安全](docs/development/ble-recovery-compatibility.zh_CN.md)。

## macOS 快速开始

普通用户从 Release 下载 `AI-Passport-macOS.zip`，把 `AI Passport.app` 移到
“应用程序”并打开即可。它是通用原生程序，不捆绑也不依赖 Python。只需安装一次
BlackHole 2ch，再配对已经运行兼容固件的 AI Passport。

如果要从源码构建同一个 App（需要 Xcode Command Line Tools）：

```bash
git clone https://github.com/ihonghong/ai-passport-macos-voice-remote.git
cd ai-passport-macos-voice-remote
./host/macos/install.sh --dry-run
./host/macos/install.sh --yes
./host/macos/doctor.sh
```

安装脚本会构建一个原生 App，并且只安装 Mac 主机端，**不会**刷写开发板、擦除设备身份数据或重置蓝牙配对。
如果脚本刚安装 BlackHole，请重启 macOS 后再次运行安装脚本，然后在“系统设置 >
蓝牙”中配对 `AI Passport`。

语音键会按住并发送**左 Control + 左 Command**。用户需要在自己选择的听写应用或输入法
中，把全局语音快捷键绑定成同一组合；安装器不会自动配置豆包或任何其他输入法。

已有主机配置会被保留。可以编辑
`~/Library/Application Support/AI Passport Bridge/config.json` 选择音频设备或指标
Provider。指标默认关闭。可选的 Codex Provider 会通过本地 Codex CLI 读取额度，并从
本机 `~/.codex` 会话记录读取 Token 计数事件；这些记录不会上传。

固件构建、按键映射、权限、排障、卸载与安全刷写步骤见
[完整 macOS 指南](host/macos/README.zh_CN.md)。硬件契约和仓库结构见
[产品与固件总览](docs/README.zh_CN.md)。

## 可选插件

- 指标 Provider：原生 App 支持 `codex`、`auto` 和不读取私人数据的默认 `none`；
  旧 Python 适配器仅保留为插件参考。
- [宠物插件](main/plugins/pets/README.zh_CN.md)：可以不带宠物、接入可再分发的自定义
  宠物，或在本地素材存在时使用所有者自己的宠物。

## 交给 Agent 安装

把仓库交给代码 Agent，并直接发送：

```text
阅读 AGENTS.zh_CN.md 和 host/macos/README.zh_CN.md，保留已有改动和正在运行的服务。
先运行 ./host/macos/install.sh --dry-run，再安装 macOS 主机端并运行
./host/macos/doctor.sh。提醒我把听写应用或输入法的语音快捷键绑定为左 Control + 左
Command；未经我允许，不要替我配置输入法。除非我明确要求，否则不要擦除 Flash、
重置配对或刷写固件。分别报告主机检查与真机检查结果。
```

AI 贡献者必须从 [AGENTS.zh_CN.md](AGENTS.zh_CN.md) 开始；人工贡献者可阅读
[CONTRIBUTING.zh_CN.md](.github/CONTRIBUTING.zh_CN.md)。项目采用 [LICENSE](LICENSE)；
可选素材必须自行具备可再分发授权。
