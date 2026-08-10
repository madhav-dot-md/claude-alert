#!/usr/bin/env bash
# The detached alarm. Not invoked by hooks directly — alert-start.sh spawns it.
# Usage: alert-loop.sh <sound> <max-repeats> <interval-seconds> [pidfile]
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/claude-alert/scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

SOUND="${1:-}"
MAX="$(alert_num "${2:-}" 15)"
INTERVAL="$(alert_num "${3:-}" 20)"
PIDFILE="${4:-}"
CHILD=""

[ -n "$SOUND" ] || exit 0

# shellcheck disable=SC2329 # invoked indirectly, via the trap calls below
cleanup() {
  # Silence whatever is playing right now rather than letting it finish.
  [ -n "$CHILD" ] && kill -TERM "$CHILD" 2>/dev/null
  # Only remove the pidfile if it is still ours; a newer alarm may own it.
  if [ -n "$PIDFILE" ] && [ -f "$PIDFILE" ] && [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ]; then
    rm -f "$PIDFILE"
  fi
  # Idempotent: the TERM/INT trap and the EXIT trap both run cleanup on a
  # signal-triggered exit. Clearing CHILD and disarming the EXIT trap stops
  # the second call from re-sending TERM to a PID that may already have
  # been reaped and reused by something else.
  CHILD=""
  trap - EXIT
}
# Installed before the pidfile write: a TERM arriving in that window must
# still be caught, or a stale pidfile is left behind for nothing to own.
trap 'cleanup; exit 0' TERM INT
trap cleanup EXIT

if [ -n "$PIDFILE" ]; then
  printf '%s' "$$" > "$PIDFILE" 2>/dev/null || { alert_log "failed to write pidfile: $PIDFILE"; PIDFILE=""; }
fi

i=0
while [ "$i" -lt "$MAX" ]; do
  # Background alert_exec_player directly (not alert_play): backgrounding a
  # function call forks exactly one subshell, and the exec inside it
  # replaces that subshell with the player — so $CHILD is the player's own
  # PID and a TERM sent to it lands on the player, not a wrapper that can
  # die and orphan the player underneath it.
  alert_exec_player "$SOUND" & CHILD=$!
  wait "$CHILD" 2>/dev/null
  CHILD=""
  i=$((i + 1))
  [ "$i" -lt "$MAX" ] || break
  sleep "$INTERVAL" & CHILD=$!
  wait "$CHILD" 2>/dev/null
  CHILD=""
done
exit 0
