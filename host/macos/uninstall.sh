#!/bin/zsh
set -euo pipefail

SUPPORT_DIR=${AI_PASSPORT_SUPPORT_DIR:-"$HOME/Library/Application Support/AI Passport Bridge"}
PASSPORT_APP=${AI_PASSPORT_APP:-"$HOME/Applications/AI Passport.app"}
LAUNCH_DIR=${AI_PASSPORT_LAUNCH_DIR:-"$HOME/Library/LaunchAgents"}
DOMAIN="gui/$(id -u)"

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

if [[ ${1:-} != "--yes" ]]; then
  print "This removes the AI Passport app and its local configuration."
  print "BlackHole and Bluetooth pairing are not removed."
  read "answer?Continue? [y/N] "
  [[ $answer == [yY] ]] || exit 0
fi

if [[ -x "$PASSPORT_APP/Contents/MacOS/AI Passport" ]]; then
  "$PASSPORT_APP/Contents/MacOS/AI Passport" --unregister-login-item || true
fi
for app_pid in ${(f)"$(pgrep -f -x "$PASSPORT_APP/Contents/MacOS/AI Passport" 2>/dev/null)"}; do
  [[ -n $app_pid ]] && kill "$app_pid" 2>/dev/null || true
done
if [[ "$LAUNCH_DIR" == "${HOME:A}/Library/LaunchAgents" ]]; then
  launchctl bootout "$DOMAIN/com.aipassport.bridge" 2>/dev/null || true
  launchctl bootout "$DOMAIN/com.aipassport.status" 2>/dev/null || true
fi
rm -f -- "$LAUNCH_DIR/com.aipassport.bridge.plist" \
  "$LAUNCH_DIR/com.aipassport.status.plist"
rm -rf -- "$SUPPORT_DIR"
rm -rf -- "$PASSPORT_APP"
print "AI Passport macOS app removed. BlackHole and Bluetooth pairing remain."
