#!/usr/bin/env bash
# Notification hook entry point. Arms the alert and returns immediately.
# Usage: alert-start.sh --loop | --once
# Exits 0 on every path: a failure here must never block a Claude Code session.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/claude-alert/scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

MODE="${1:---loop}"

# Always drain stdin, even when muted, so the writer never sees EPIPE.
RAW="$(cat)"

[ "${CLAUDE_ALERT_DISABLE:-}" = "1" ] && exit 0

SESSION_RAW="$(alert_json_field session_id "$RAW")"
if [ -z "$SESSION_RAW" ]; then
  alert_log "start: no session_id in payload, ignoring"
  exit 0
fi
SESSION="$(alert_sanitize_id "$SESSION_RAW")"
if [ -z "$SESSION" ]; then
  alert_log "start: session_id sanitised to empty, ignoring"
  exit 0
fi

SOUND="$(alert_resolve_sound)" || { alert_log "start: no sound file resolvable"; exit 0; }

# Without a player, the loop would still run every iteration for the full
# repeat cap, just to log failure each time and hold a live pidfile for
# nothing. Fail here instead of arming.
if ! alert_player >/dev/null; then
  alert_log "start: no audio player available, not arming"
  exit 0
fi

INTERVAL="$(alert_num "${CLAUDE_ALERT_INTERVAL:-}" 20)"
MAX="$(alert_num "${CLAUDE_ALERT_MAX:-}" 15)"

# A one-shot needs no state at all.
if [ "$MODE" = "--once" ]; then
  ( nohup "$SCRIPT_DIR/alert-loop.sh" "$SOUND" 1 0 </dev/null >/dev/null 2>&1 & )
  exit 0
fi

STATE_DIR="$(alert_safe_state_dir create)"
if [ -z "$STATE_DIR" ]; then
  alert_log "start: state dir unusable, degrading to a single play"
  ( nohup "$SCRIPT_DIR/alert-loop.sh" "$SOUND" 1 0 </dev/null >/dev/null 2>&1 & )
  exit 0
fi

PIDFILE="$STATE_DIR/$SESSION.pid"

# Never stack audio: cancel whatever this session already had running.
alert_kill_pidfile "$PIDFILE"

# Double-fork so the loop survives the hook's process group being reaped.
# The loop writes its own PID into PIDFILE as its first action.
( nohup "$SCRIPT_DIR/alert-loop.sh" "$SOUND" "$MAX" "$INTERVAL" "$PIDFILE" </dev/null >/dev/null 2>&1 & )
exit 0
