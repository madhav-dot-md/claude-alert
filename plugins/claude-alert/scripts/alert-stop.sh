#!/usr/bin/env bash
# Disarm entry point for UserPromptSubmit, PostToolUse, PermissionDenied and
# SessionEnd. PostToolUse fires on every single tool call, so the common path
# — nothing armed — must stay as close to free as possible.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/claude-alert/scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

RAW="$(cat)"

STATE_DIR="$(alert_state_dir)"
[ -d "$STATE_DIR" ] || exit 0

# Fast path: no alarm armed anywhere, so skip parsing entirely.
set -- "$STATE_DIR"/*.pid
[ -e "$1" ] || exit 0

SESSION_RAW="$(alert_json_field session_id "$RAW")"
[ -n "$SESSION_RAW" ] || exit 0

alert_kill_pidfile "$STATE_DIR/$(alert_sanitize_id "$SESSION_RAW").pid"
exit 0
