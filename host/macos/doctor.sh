#!/bin/zsh
set -u

SCRIPT_DIR=${0:A:h}
SUPPORT_DIR=${AI_PASSPORT_SUPPORT_DIR:-"$HOME/Library/Application Support/AI Passport Bridge"}
STATUS_APP=${AI_PASSPORT_STATUS_APP:-"$HOME/Applications/AI Passport Status.app"}
FAILURES=0

check() {
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then
    print "PASS  $label"
  else
    print "FAIL  $label"
    FAILURES=$((FAILURES + 1))
  fi
}

check "macOS" test "$(uname -s)" = Darwin
check "Python 3" command -v python3
check "Xcode Command Line Tools" command -v xcrun
check "BlackHole 2ch" zsh -c 'system_profiler SPAudioDataType | grep -q "BlackHole 2ch"'
check "Bridge source self-test" python3 "$SCRIPT_DIR/bridge/mac_shortcut_bridge.py" --self-test

if [[ -x "$SUPPORT_DIR/venv/bin/python" ]]; then
  check "Installed Python dependencies" "$SUPPORT_DIR/venv/bin/python" -c 'import hid, sounddevice'
  check "Installed bridge configuration" "$SUPPORT_DIR/venv/bin/python" \
    "$SUPPORT_DIR/bridge/mac_shortcut_bridge.py" --config "$SUPPORT_DIR/config.json" \
    --print-effective-config
else
  print "INFO  Host is not installed at $SUPPORT_DIR"
fi

[[ -x "$STATUS_APP/Contents/MacOS/AI Passport Status" ]] \
  && print "PASS  Status menu app" || print "INFO  Status menu app is not installed"

if [[ "$STATUS_APP" != "/Applications/AI Passport Status.app" && \
      -x "/Applications/AI Passport Status.app/Contents/MacOS/AI Passport Status" ]]; then
  print "INFO  Unused legacy status app remains in /Applications"
fi

if [[ -f "$SUPPORT_DIR/mac_shortcut_bridge.py" ]]; then
  print "INFO  Legacy Bridge layout found; rerun install.sh to migrate"
fi

BRIDGE_STATE=$(launchctl print "gui/$(id -u)/com.aipassport.bridge" 2>/dev/null || true)
if [[ -n $BRIDGE_STATE && $BRIDGE_STATE == *"$SUPPORT_DIR/bridge/mac_shortcut_bridge.py"* ]]; then
  print "PASS  Bridge LaunchAgent"
elif [[ -n $BRIDGE_STATE && $BRIDGE_STATE == *"$SUPPORT_DIR/mac_shortcut_bridge.py"* ]]; then
  print "INFO  Legacy Bridge LaunchAgent is running; rerun install.sh to migrate"
elif [[ -n $BRIDGE_STATE ]]; then
  print "INFO  Bridge LaunchAgent belongs to another installation"
else
  print "INFO  Bridge LaunchAgent is not running"
fi

if [[ -f "$SUPPORT_DIR/status.json" ]]; then
  print "STATE $(cat "$SUPPORT_DIR/status.json")"
fi

exit $((FAILURES > 0 ? 1 : 0))
