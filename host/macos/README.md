<p align="right">
  <a href="README.zh_CN.md">简体中文</a> · <strong>English</strong>
</p>

# macOS Host

The macOS host turns AI Passport into a wireless push-to-talk remote and
microphone for dictation. The native menu-bar application contains the BLE HID
Bridge, PCM conversion, Core Audio output, input-device policy, shortcut
configuration, and optional metrics. Python is not a runtime dependency.

## What runs on the Mac

```text
AI Passport BLE HID
  ├─ keyboard reports ─────────────────> macOS shortcuts / Return / Command-Delete
  ├─ microphone reports -> native App ─> BlackHole 2ch -> dictation application
  └─ status reports <--- native App ──── quota, daily tokens, date/time, audio readiness
```

The device remains paired as one Bluetooth HID device. One native Swift process
receives its vendor audio reports through IOKit and writes converted 48 kHz
stereo PCM through Core Audio. BlackHole remains the only external runtime
dependency because a normal app cannot register itself as a system microphone
driver. The app also switches between AI Passport input and the previously
selected physical microphone.

## Requirements

- macOS with Bluetooth LE
- BlackHole 2ch (Homebrew is one installation option)
- an AI Passport running this repository's shortcut firmware

The downloadable universal App supports Apple silicon and Intel Macs. Xcode
Command Line Tools are required only when building the App from source.

## Install

For a release, download `AI-Passport-macOS.zip`, move `AI Passport.app` into
Applications, and try to open it. Public releases are precompiled universal
Unsigned Beta builds, so no source build or Apple Developer account is required.
Because they are not notarized, the first launch requires **System Settings >
Privacy & Security > Open Anyway**. Confirm the prompt, then open the App again.

To build and install from a clone, run:

```bash
./host/macos/install.sh --dry-run
./host/macos/install.sh --yes
```

If BlackHole is installed during this run, restart macOS and run the installer
again. Then open **System Settings > Bluetooth**, connect **AI Passport**, and
allow **AI Passport** under **Privacy & Security > Input Monitoring** when macOS
asks. This permission is required because the board exposes its
wireless-audio channel inside the same composite HID device that macOS identifies
as a keyboard. Ad-hoc App updates may change the identity macOS associates with
this permission, so enable the new entry again if an upgrade stops receiving
device input. Restart the App after granting access, then verify the installation:

```bash
./host/macos/doctor.sh
```

The source installer creates only user-owned files:

- `~/Library/Application Support/AI Passport Bridge/`
- `~/Applications/AI Passport.app`

It preserves an existing `config.json`, retires the old Python/LaunchAgent
runtime, and lets the App register itself as a macOS login item. It does not
flash the device, erase Bluetooth pairing, or uninstall BlackHole.

## Configure the physical buttons

The configuration binds the three physical controls directly: `up`, `mid`, and
`down`. It does not assign fixed voice, send, or delete semantics. The default
`mid` name corresponds to the board support package's historical `OK` label. The
`down` binding holds **Left Control + Left Command**; this is an AI Passport
project default, not a universal macOS, Dictation, or input-method shortcut.
Every user must configure their preferred dictation application or input method
to use exactly that combination as its global voice trigger. The host installer
deliberately does not install or configure Doubao, macOS Dictation, or another
input method.

After binding it, select **AI Passport input** from the menu-bar app, focus a
text field, hold the physical Down button, speak, and release it. If the chosen
application has its own microphone selector, choose `BlackHole 2ch` there as
well. By default, Mid emits Return and Up emits Command-Delete.

**AI Passport input** keeps `BlackHole 2ch` selected while the bridge is
connected to the device. If the bridge stops, fails, or waits for the device,
the menu-bar app temporarily restores the previous physical microphone so the
system is not left on a silent virtual input. It resumes Passport input after a
reconnection. Selecting **Meeting input (physical microphone)** disables that
automatic resume until **AI Passport input** is selected again.

## Configuration

Choose **Open configuration file** from the menu-bar item, edit it, then choose
**Apply latest configuration (restart audio bridge)**. Saving the file alone
does not change the running configuration; restarting reloads the file and
sends the latest button mappings to the device. The file lives at
`~/Library/Application Support/AI Passport Bridge/config.json`:

```json
{
  "device_name": "AI Passport",
  "audio_device": "BlackHole 2ch",
  "buttons": {
    "up": { "modifiers": ["left_command"], "key": "delete" },
    "mid": { "modifiers": [], "key": "return" },
    "down": { "modifiers": ["left_control", "left_command"], "key": null }
  },
  "provider": {
    "name": "none",
    "settings": { "refresh_seconds": 300 }
  }
}
```

The Bridge sends the complete `up` / `mid` / `down` map through the existing HID
Output Report after connecting. Firmware validates its checksum and stores a
changed map in NVS; unchanged maps do not write Flash. This does not change the
HID descriptor or require re-pairing. The physical Down button still controls
the microphone stream while held; its configured chord only determines which
keyboard shortcut is held at the same time. Up and Mid send their configured
chords as taps. Supported modifier names are `left_control`, `left_shift`,
`left_option`, `left_command`, and their `right_` equivalents. Named keys are
`return`, `escape`, `delete`, and `space`; a USB HID usage from `0` through `101`
may be supplied as an integer. At least one modifier or key is required for
every button. Restart the Bridge after editing, and configure the dictation
application to use the same Down-button chord.

Existing installations that still contain the earlier `shortcuts.voice`,
`shortcuts.send`, and `shortcuts.clear` fields are migrated in memory to Down,
Mid, and Up respectively. The former physical key name `buttons.ok` is also
migrated to `buttons.mid`. New configurations should only use `buttons`.

Metrics are disabled by default. Set `provider.name` to `codex` or `auto` to opt
in. The native Codex Provider reads rate limits
from the local Codex CLI and token-count events from local `~/.codex` session
records; it does not upload those records. Provider polling is periodic and does
not keep a separate Bluetooth connection open; status values ride on the
existing HID connection. The old Python Bridge remains in the repository as a
diagnostic and migration reference; the installed App does not load it.

Run the legacy Bridge manually only when comparing behavior during diagnosis:

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

This unregisters the login item and removes the native App and its local
configuration. It leaves BlackHole, Bluetooth pairing, and device firmware intact.

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
