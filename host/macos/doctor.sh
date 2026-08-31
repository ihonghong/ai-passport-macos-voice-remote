#!/bin/zsh
set -u

SUPPORT_DIR=${AI_PASSPORT_SUPPORT_DIR:-"$HOME/Library/Application Support/AI Passport Bridge"}
PASSPORT_APP=${AI_PASSPORT_APP:-"$HOME/Applications/AI Passport.app"}
EXECUTABLE="$PASSPORT_APP/Contents/MacOS/AI Passport"
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
check "BlackHole 2ch" zsh -c 'system_profiler SPAudioDataType | grep -q "BlackHole 2ch"'
check "Native AI Passport app" test -x "$EXECUTABLE"
if [[ -x "$EXECUTABLE" ]]; then
  check "App code signature" codesign --verify --deep --strict "$PASSPORT_APP"
  check "App is running" pgrep -f "^${EXECUTABLE}$"
  print "INPUT $($EXECUTABLE --print-default-input 2>/dev/null || print unknown)"
fi

if [[ -f "$SUPPORT_DIR/status.json" ]]; then
  state=$(plutil -extract state raw "$SUPPORT_DIR/status.json" 2>/dev/null || print unknown)
  detail=$(plutil -extract detail raw "$SUPPORT_DIR/status.json" 2>/dev/null || print unknown)
  case "$state" in
    connected|recording) print "PASS  Bridge device connection ($state)" ;;
    waiting) print "INFO  Bridge is waiting for the device" ;;
    error)
      print "FAIL  Bridge runtime: $detail"
      FAILURES=$((FAILURES + 1))
      ;;
    *) print "INFO  Bridge runtime state: $state" ;;
  esac
fi

if [[ -f "$SUPPORT_DIR/config.json" ]]; then
  if [[ -x "$EXECUTABLE" ]]; then
    check "Bridge configuration" "$EXECUTABLE" \
      --validate-config "$SUPPORT_DIR/config.json"
  else
    print "FAIL  Bridge configuration (native validator is unavailable)"
    FAILURES=$((FAILURES + 1))
  fi
else
  print "INFO  Default configuration is active; no user config file exists yet"
fi

if launchctl print "gui/$(id -u)/com.aipassport.bridge" >/dev/null 2>&1; then
  print "INFO  Retired Python Bridge LaunchAgent is still registered; rerun install.sh"
fi
if [[ -d "$SUPPORT_DIR/venv" ]]; then
  print "INFO  Retired Python environment remains; native App does not use it"
fi

exit $((FAILURES > 0 ? 1 : 0))
