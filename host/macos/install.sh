#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_ROOT=${SCRIPT_DIR:h:h}
SUPPORT_DIR=${AI_PASSPORT_SUPPORT_DIR:-"$HOME/Library/Application Support/AI Passport Bridge"}
STATUS_APP=${AI_PASSPORT_STATUS_APP:-"$HOME/Applications/AI Passport Status.app"}
LAUNCH_DIR=${AI_PASSPORT_LAUNCH_DIR:-"$HOME/Library/LaunchAgents"}
LOG_DIR=${AI_PASSPORT_LOG_DIR:-"$HOME/Library/Logs"}
YES=0
DRY_RUN=0
SKIP_START=0

safe_named_path() {
  local label=$1
  local candidate=$2
  local expected_leaf=$3
  candidate=${candidate:A}
  if [[ -z $candidate || $candidate == / || $candidate == ${HOME:A} || \
        ${candidate:t} != $expected_leaf ]]; then
    print -u2 "Refusing unsafe $label path: $candidate"
    exit 2
  fi
  REPLY=$candidate
}

safe_named_path "support directory" "$SUPPORT_DIR" "AI Passport Bridge"
SUPPORT_DIR=$REPLY
safe_named_path "status app" "$STATUS_APP" "AI Passport Status.app"
STATUS_APP=$REPLY
safe_named_path "LaunchAgents directory" "$LAUNCH_DIR" "LaunchAgents"
LAUNCH_DIR=$REPLY
safe_named_path "log directory" "$LOG_DIR" "Logs"
LOG_DIR=$REPLY

usage() {
  cat <<'EOF'
Usage: ./host/macos/install.sh [--yes] [--dry-run] [--skip-start]

  --yes         Install BlackHole with Homebrew when it is missing.
  --dry-run     Print resolved locations without changing the machine.
  --skip-start  Install files but do not replace or start LaunchAgents.
EOF
}

while (( $# )); do
  case "$1" in
    --yes) YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --skip-start) SKIP_START=1 ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "Unknown option: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

print "AI Passport macOS host installer"
print "  repository: $REPO_ROOT"
print "  bridge:     $SUPPORT_DIR"
print "  status app: $STATUS_APP"
print "  agents:     $LAUNCH_DIR"

if (( DRY_RUN )); then
  print "Dry run only; no files or services were changed."
  exit 0
fi

[[ $(uname -s) == Darwin ]] || { print -u2 "macOS is required"; exit 1; }
command -v python3 >/dev/null || { print -u2 "python3 is required"; exit 1; }
command -v xcrun >/dev/null || { print -u2 "Xcode Command Line Tools are required"; exit 1; }

LEGACY_BRIDGE=0
if [[ -f "$SUPPORT_DIR/mac_shortcut_bridge.py" ]]; then
  LEGACY_BRIDGE=1
  print "Legacy Bridge layout detected; installing the current layout in place."
fi
if [[ -d "/Applications/AI Passport Status.app" && \
      "$STATUS_APP" != "/Applications/AI Passport Status.app" ]]; then
  print "Legacy status app detected at /Applications/AI Passport Status.app."
  print "It is left untouched; the current app will be installed at $STATUS_APP."
fi

if ! system_profiler SPAudioDataType 2>/dev/null | grep -q "BlackHole 2ch"; then
  if (( YES )) && command -v brew >/dev/null; then
    print "Installing BlackHole 2ch with Homebrew..."
    brew install blackhole-2ch
    print "BlackHole was installed. Restart macOS, then rerun this installer."
    exit 3
  fi
  print -u2 "BlackHole 2ch is required for the virtual microphone."
  print -u2 "Install it with: brew install blackhole-2ch"
  print -u2 "Restart macOS after installation, then rerun this installer."
  exit 1
fi

mkdir -p "$SUPPORT_DIR/bridge" "$STATUS_APP/Contents/MacOS" \
  "$STATUS_APP/Contents/Resources" "$LAUNCH_DIR" "$LOG_DIR"
cp "$SCRIPT_DIR/bridge/mac_shortcut_bridge.py" "$SUPPORT_DIR/bridge/"
cp "$SCRIPT_DIR/bridge/configuration.py" "$SUPPORT_DIR/bridge/"
PROVIDERS_DIR="$SUPPORT_DIR/bridge/providers"
safe_named_path "provider directory" "$PROVIDERS_DIR" "providers"
[[ ${PROVIDERS_DIR:h} == "$SUPPORT_DIR/bridge" ]] || {
  print -u2 "Refusing provider path outside the Bridge directory: $PROVIDERS_DIR"
  exit 2
}
rm -rf "$PROVIDERS_DIR"
cp -R "$SCRIPT_DIR/bridge/providers" "$SUPPORT_DIR/bridge/providers"
cp "$SCRIPT_DIR/bridge/requirements.txt" "$SUPPORT_DIR/bridge/"

if [[ ! -f "$SUPPORT_DIR/config.json" ]]; then
  cp "$SCRIPT_DIR/bridge/config.example.json" "$SUPPORT_DIR/config.json"
  if (( LEGACY_BRIDGE )); then
    CONFIG_PATH="$SUPPORT_DIR/config.json" python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["CONFIG_PATH"])
config = json.loads(path.read_text(encoding="utf-8"))
config["provider"]["name"] = "auto"
path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
PY
    print "Preserved the legacy automatic metric-provider behavior."
  fi
fi

if [[ ! -x "$SUPPORT_DIR/venv/bin/python" ]]; then
  python3 -m venv "$SUPPORT_DIR/venv"
fi
"$SUPPORT_DIR/venv/bin/python" -m pip install --disable-pip-version-check \
  -r "$SUPPORT_DIR/bridge/requirements.txt"

xcrun swiftc -parse-as-library -O "$SCRIPT_DIR/statusbar/mac_status_bar.swift" \
  -o "$STATUS_APP/Contents/MacOS/AI Passport Status" \
  -framework AppKit -framework CoreAudio
cp "$SCRIPT_DIR/statusbar/Info.plist" "$STATUS_APP/Contents/Info.plist"

render_plist() {
  local template=$1
  local destination=$2
  TEMPLATE_PATH=$template DESTINATION_PATH=$destination \
    SUPPORT_VALUE=$SUPPORT_DIR STATUS_VALUE=$STATUS_APP LOG_VALUE=$LOG_DIR \
    python3 - <<'PY'
import html
import os
from pathlib import Path

text = Path(os.environ["TEMPLATE_PATH"]).read_text(encoding="utf-8")
values = {
    "@SUPPORT_DIR@": os.environ["SUPPORT_VALUE"],
    "@STATUS_APP@": os.environ["STATUS_VALUE"],
    "@LOG_DIR@": os.environ["LOG_VALUE"],
}
for marker, value in values.items():
    text = text.replace(marker, html.escape(value))
Path(os.environ["DESTINATION_PATH"]).write_text(text, encoding="utf-8")
PY
}

BRIDGE_PLIST="$LAUNCH_DIR/com.aipassport.bridge.plist"
STATUS_PLIST="$LAUNCH_DIR/com.aipassport.status.plist"
render_plist "$SCRIPT_DIR/launchagents/com.aipassport.bridge.plist.template" "$BRIDGE_PLIST"
render_plist "$SCRIPT_DIR/launchagents/com.aipassport.status.plist.template" "$STATUS_PLIST"
plutil -lint "$BRIDGE_PLIST" "$STATUS_PLIST" >/dev/null

"$SUPPORT_DIR/venv/bin/python" "$SUPPORT_DIR/bridge/mac_shortcut_bridge.py" \
  --config "$SUPPORT_DIR/config.json" --self-test

if (( LEGACY_BRIDGE )) && [[ -f "$SUPPORT_DIR/mac_shortcut_bridge.py" ]]; then
  LEGACY_BACKUP_DIR="$SUPPORT_DIR/legacy"
  safe_named_path "legacy backup directory" "$LEGACY_BACKUP_DIR" "legacy"
  mkdir -p "$LEGACY_BACKUP_DIR"
  if [[ ! -e "$LEGACY_BACKUP_DIR/mac_shortcut_bridge.py" ]]; then
    mv "$SUPPORT_DIR/mac_shortcut_bridge.py" \
      "$LEGACY_BACKUP_DIR/mac_shortcut_bridge.py"
    print "Moved the legacy Bridge entry point to $LEGACY_BACKUP_DIR."
  fi
fi

if (( ! SKIP_START )); then
  DOMAIN="gui/$(id -u)"

  bootstrap_agent() {
    local label=$1
    local plist=$2
    local attempt
    for attempt in 1 2 3 4; do
      if launchctl bootstrap "$DOMAIN" "$plist"; then
        return 0
      fi
      if (( attempt == 4 )); then
        print -u2 "Unable to register LaunchAgent after waiting for macOS: $label"
        return 1
      fi
      print "Retrying LaunchAgent registration after macOS finishes unloading $label..."
      sleep "$attempt"
    done
  }

  launchctl bootout "$DOMAIN/com.aipassport.bridge" 2>/dev/null || true
  launchctl bootout "$DOMAIN/com.aipassport.status" 2>/dev/null || true
  bootstrap_agent "com.aipassport.bridge" "$BRIDGE_PLIST"
  bootstrap_agent "com.aipassport.status" "$STATUS_PLIST"
  launchctl enable "$DOMAIN/com.aipassport.bridge"
  launchctl enable "$DOMAIN/com.aipassport.status"
  launchctl kickstart -k "$DOMAIN/com.aipassport.bridge"
  launchctl kickstart -k "$DOMAIN/com.aipassport.status"
fi

print "Installation complete. Pair AI Passport in System Settings > Bluetooth."
print "Run ./host/macos/doctor.sh to verify the host after pairing."
