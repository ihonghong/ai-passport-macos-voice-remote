#!/bin/zsh
set -euo pipefail

SUPPORT_DIR=${AI_PASSPORT_SUPPORT_DIR:-"$HOME/Library/Application Support/AI Passport Bridge"}
STATUS_APP=${AI_PASSPORT_STATUS_APP:-"$HOME/Applications/AI Passport Status.app"}
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
safe_named_path "status app" "$STATUS_APP" "AI Passport Status.app"
STATUS_APP=$REPLY
safe_named_path "LaunchAgents directory" "$LAUNCH_DIR" "LaunchAgents"
LAUNCH_DIR=$REPLY

if [[ ${1:-} != "--yes" ]]; then
  print "This removes the AI Passport host service, its app, and local configuration."
  print "BlackHole and Bluetooth pairing are not removed."
  read "answer?Continue? [y/N] "
  [[ $answer == [yY] ]] || exit 0
fi

launchctl bootout "$DOMAIN/com.aipassport.bridge" 2>/dev/null || true
launchctl bootout "$DOMAIN/com.aipassport.status" 2>/dev/null || true
rm -f -- "$LAUNCH_DIR/com.aipassport.bridge.plist"
rm -f -- "$LAUNCH_DIR/com.aipassport.status.plist"
rm -rf -- "$SUPPORT_DIR"
rm -rf -- "$STATUS_APP"
print "AI Passport macOS host removed. Logs remain under $HOME/Library/Logs."
