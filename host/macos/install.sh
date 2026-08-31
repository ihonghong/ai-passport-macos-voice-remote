#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
SUPPORT_DIR=${AI_PASSPORT_SUPPORT_DIR:-"$HOME/Library/Application Support/AI Passport Bridge"}
PASSPORT_APP=${AI_PASSPORT_APP:-"$HOME/Applications/AI Passport.app"}
LAUNCH_DIR=${AI_PASSPORT_LAUNCH_DIR:-"$HOME/Library/LaunchAgents"}
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
safe_named_path "application" "$PASSPORT_APP" "AI Passport.app"
PASSPORT_APP=$REPLY
safe_named_path "LaunchAgents directory" "$LAUNCH_DIR" "LaunchAgents"
LAUNCH_DIR=$REPLY

usage() {
  cat <<'EOF'
Usage: ./host/macos/install.sh [--yes] [--dry-run] [--skip-start]

  --yes         Install BlackHole with Homebrew when it is missing.
  --dry-run     Print resolved locations without changing the machine.
  --skip-start  Install the app but do not open it.
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

print "AI Passport native macOS installer"
print "  source:  $SCRIPT_DIR"
print "  app:     $PASSPORT_APP"
print "  config:  $SUPPORT_DIR/config.json"
print "  runtime: native Swift (no Python environment)"

if (( DRY_RUN )); then
  print "Dry run only; no files or services were changed."
  exit 0
fi

[[ $(uname -s) == Darwin ]] || { print -u2 "macOS is required"; exit 1; }
command -v xcrun >/dev/null || { print -u2 "Xcode Command Line Tools are required"; exit 1; }

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

mkdir -p "$SUPPORT_DIR" "${PASSPORT_APP:h}" "$LAUNCH_DIR"
if [[ ! -f "$SUPPORT_DIR/config.json" ]]; then
  cp "$SCRIPT_DIR/bridge/config.example.json" "$SUPPORT_DIR/config.json"
fi

BUILD_OUTPUT=$(mktemp -d /tmp/ai-passport-install.XXXXXX)
trap 'case "$BUILD_OUTPUT" in /tmp/ai-passport-install.*) rm -rf -- "$BUILD_OUTPUT" ;; esac' EXIT
AI_PASSPORT_OUTPUT_DIR="$BUILD_OUTPUT" \
AI_PASSPORT_ARCHS="$(uname -m)" \
  "$SCRIPT_DIR/build-app.sh"

if [[ -e "$PASSPORT_APP" ]]; then
  [[ ${PASSPORT_APP:t} == "AI Passport.app" ]] || { print -u2 "Unsafe app path"; exit 2; }
  rm -rf -- "$PASSPORT_APP"
fi
ditto --norsrc --noextattr --noacl "$BUILD_OUTPUT/AI Passport.app" "$PASSPORT_APP"

# Stop the retired two-process installation after the replacement is ready.
DOMAIN="gui/$(id -u)"
if [[ "$LAUNCH_DIR" == "${HOME:A}/Library/LaunchAgents" ]]; then
  launchctl bootout "$DOMAIN/com.aipassport.bridge" 2>/dev/null || true
  launchctl bootout "$DOMAIN/com.aipassport.status" 2>/dev/null || true
fi
rm -f -- "$LAUNCH_DIR/com.aipassport.bridge.plist" \
  "$LAUNCH_DIR/com.aipassport.status.plist"

if (( ! SKIP_START )); then
  open "$PASSPORT_APP"
fi

print "Installation complete. Pair AI Passport in System Settings > Bluetooth."
print "The menu-bar app now contains the BLE and audio Bridge itself."
