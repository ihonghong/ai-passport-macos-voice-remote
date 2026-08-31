<p align="right">
  <a href="README.zh_CN.md">简体中文</a> · <strong>English</strong>
</p>

# macOS Host

The macOS host turns AI Passport into a wireless push-to-talk remote and
microphone for dictation. It contains the Python audio bridge, the menu-bar
status application, LaunchAgent templates, configuration, and repeatable
install, diagnostic, and uninstall scripts.

## What runs on the Mac

```text
AI Passport BLE HID
  ├─ keyboard reports ───────────────> macOS shortcuts / Return / Command-Delete
  ├─ microphone reports -> bridge ───> BlackHole 2ch -> dictation application
  └─ status reports <--- provider ──── quota, daily tokens, date/time, audio readiness
```

The device remains paired as one Bluetooth HID device. The Python bridge is a
background process because macOS applications need a local component to turn
the custom BLE audio reports into a CoreAudio input stream. BlackHole provides
that virtual input. The menu-bar application shows status and switches between
AI Passport input and the previously selected physical microphone.

## Requirements

- macOS with Bluetooth LE
- Python 3.9 or newer
- Xcode Command Line Tools (`xcode-select --install`)
- Homebrew when the installer needs to install BlackHole
- an AI Passport running this repository's shortcut firmware

## Install

Clone the repository and run:

```bash
./host/macos/install.sh --dry-run
./host/macos/install.sh --yes
```

If BlackHole is installed during this run, restart macOS and run the installer
again. Then open **System Settings > Bluetooth**, connect **AI Passport**, and
verify the installation:

```bash
./host/macos/doctor.sh
```

The installer creates only user-owned files:

- `~/Library/Application Support/AI Passport Bridge/`
- `~/Applications/AI Passport Status.app`
- `~/Library/LaunchAgents/com.aipassport.bridge.plist`
- `~/Library/LaunchAgents/com.aipassport.status.plist`

It preserves an existing `config.json` during upgrades. It does not flash the
device, erase Bluetooth pairing, or uninstall BlackHole.

## Configure the voice shortcut

**This manual step is required before the voice button can trigger text input.**
The public firmware acts as a keyboard and defaults to holding **Left Control +
Left Command** while the voice button is held. This combination is an AI Passport
project default, not a universal macOS, Dictation, or input-method default. Every
user must configure their preferred dictation application or input method to use
exactly that combination as its global voice trigger. The host installer
deliberately does not install or configure Doubao, macOS Dictation, or another
input method.

After binding it, select **AI Passport input** from the menu-bar app, focus a
text field, hold the Passport voice button, speak, and release it. If the chosen
application has its own microphone selector, choose `BlackHole 2ch` there as
well. The send button emits Return and the clear button emits Command-Delete.

**AI Passport input** keeps `BlackHole 2ch` selected while the bridge is
connected to the device. If the bridge stops, fails, or waits for the device,
the menu-bar app temporarily restores the previous physical microphone so the
system is not left on a silent virtual input. It resumes Passport input after a
reconnection. Selecting **Meeting input (physical microphone)** disables that
automatic resume until **AI Passport input** is selected again.

## Configuration

Edit `~/Library/Application Support/AI Passport Bridge/config.json`, then choose
**Restart audio bridge** from the menu-bar item:

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

The Bridge sends the complete shortcut map through the existing HID Output
Report after connecting. Firmware validates its checksum and stores a changed
map in NVS; unchanged maps do not write Flash. This does not change the HID
descriptor or require re-pairing. Supported modifier names are `left_control`,
`left_shift`, `left_option`, `left_command`, and their `right_` equivalents.
Named keys are `return`, `escape`, `delete`, and `space`; a USB HID usage from
`0` through `101` may be supplied as an integer. At least one modifier or key is
required for every action. Restart the Bridge after editing, and configure the
dictation application to use the same voice chord.

Metrics are disabled by default. Set `provider.name` to `codex`, `auto`, or a
fully qualified Python module to opt in. The Codex Provider reads rate limits
from the local Codex CLI and token-count events from local `~/.codex` session
records; it does not upload those records. Provider polling is periodic and does
not keep a separate Bluetooth connection open; status values ride on the
existing HID connection. See [provider plugins](bridge/providers/README.md).

Run the bridge manually only for diagnosis:

```bash
python3 host/macos/bridge/mac_shortcut_bridge.py --self-test
python3 host/macos/bridge/mac_shortcut_bridge.py --print-effective-config
```

## Firmware and pairing safety

Use ESP-IDF 5.5.3. On a provisioned device, use segmented `idf.py flash` during
development, or use permanent Recovery and the official mini-program for a
normal release installation. Never run `idf.py erase-flash`: it destroys the
per-device identity and permanent Recovery. Do not raw-flash the merged image at
offset `0x0` as a normal update either: its `0xFF` gap overwrites runtime NVS and
resets the Bluetooth bond, and a future resource-bearing artifact may span later
protected regions. See [BLE and Recovery compatibility](../../docs/development/ble-recovery-compatibility.md).

Changing the BLE security configuration may require deleting the old AI
Passport entry in macOS Bluetooth settings and pairing again. Normal host
upgrades do not reset pairing.

When a new bond is required, the firmware generates a fresh six-digit passkey
and shows it on the Passport display. Enter that code in the macOS Bluetooth
prompt. The code disappears after encryption succeeds or the connection closes;
an existing bonded reconnect does not show another code.

## Uninstall

```bash
./host/macos/uninstall.sh
```

This removes the host service, menu-bar app, and its local configuration. It
leaves BlackHole, logs, Bluetooth pairing, and device firmware intact.

## Agent-friendly setup

An installation agent can be given this prompt:

```text
Read AGENTS.md and host/macos/README.md. Preserve existing changes and services.
Run host/macos/install.sh --dry-run first. After confirming its paths, run
host/macos/install.sh --yes and host/macos/doctor.sh. Never erase Flash. For a
normal release install, use permanent Recovery and the official mini-program; for
development, use ESP-IDF 5.5.3 and segmented idf.py flash. Do not raw-write the
merged firmware at offset 0x0 unless the user explicitly requests USB recovery
and accepts re-pairing. Leave Bluetooth pairing in System Settings to the user and
report host checks separately from device checks.
Ask the user to bind their dictation or input-method voice shortcut to Left
Control + Left Command; do not configure an input method without approval.
```

An agent can install all host files non-interactively, but macOS may still
require the user to approve Bluetooth pairing and restart after BlackHole is
first installed.

## Troubleshooting

- No Bluetooth Connect button: remove a stale AI Passport entry, reboot the
  device, then pair from System Settings rather than from the bridge.
- Keyboard works but speech uses the Mac microphone: choose **AI Passport
  input** in the menu-bar app and confirm the dictation application follows the
  system input device.
- Voice button does nothing: bind the dictation or input-method global voice
  shortcut to **Left Control + Left Command**.
- Device says `BRIDGE OFF`: run `doctor.sh`, inspect
  `~/Library/Logs/AI Passport Bridge.log`, and restart the audio bridge.
- Meetings receive Passport audio: choose **Meeting input (physical
  microphone)** before joining the call.
- BlackHole remains selected after Passport disconnects: make sure the menu-bar
  app is running; it restores the previous physical input on its next refresh.
