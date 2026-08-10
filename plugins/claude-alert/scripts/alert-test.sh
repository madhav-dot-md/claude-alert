#!/usr/bin/env bash
# Diagnostic for /alert-test. Prints the resolved configuration in
# key=value form, then plays the sound once. Always exits 0.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

HOME_DIR="${CLAUDE_ALERT_HOME:-$HOME/.claude}"

printf 'interval=%ss\n' "$(alert_num "${CLAUDE_ALERT_INTERVAL:-}" 20)"
printf 'max=%s\n' "$(alert_num "${CLAUDE_ALERT_MAX:-}" 15)"
printf 'disabled=%s\n' "$([ "${CLAUDE_ALERT_DISABLE:-}" = "1" ] && printf yes || printf no)"

if ! SOUND="$(alert_resolve_sound)"; then
  printf 'sound=<none>\n'
  if [ -n "${CLAUDE_ALERT_SOUND:-}" ]; then
    printf 'searched=%s\n' "$CLAUDE_ALERT_SOUND"
  else
    printf 'searched=%s/alert-sound.{wav,mp3,aiff,aif,m4a,caf}, /System/Library/Sounds/Submarine.aiff\n' "$HOME_DIR"
  fi
  printf 'result=no-sound\n'
  printf 'hint=drop a short 1-3 second sound file at %s/alert-sound.wav\n' "$HOME_DIR"
  exit 0
fi
printf 'sound=%s\n' "$SOUND"

if ! PLAYER="$(alert_player)"; then
  printf 'player=<none>\n'
  printf 'result=no-player\n'
  exit 0
fi
printf 'player=%s\n' "$PLAYER"

if alert_play "$SOUND"; then
  printf 'result=ok\n'
else
  printf 'result=playback-failed\n'
fi
exit 0
