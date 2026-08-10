#!/usr/bin/env bash
# Shared helpers for claude-alert. Sourced, never executed directly.
# Nothing here may exit non-zero in a way that escapes to a hook: callers
# check return codes, but a failure must never abort a Claude Code session.

alert_state_dir() {
  printf '%s/claude-alert' "${TMPDIR:-/tmp}"
}

alert_log() {
  local dir
  dir="$(alert_state_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$dir/alert.log" 2>/dev/null || true
  return 0
}

# Extract a flat top-level string field. Only ever used for session_id and
# hook_event_name, so the grep fallback's inability to handle escaped quotes
# or nested objects is not a limitation in practice.
alert_json_field() {
  local field="$1" json="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null
    return 0
  fi
  printf '%s' "$json" \
    | grep -oE "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -n 1 \
    | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/'
}

# session_id becomes a path component, so it must not be able to escape the
# state directory. Dots are deliberately excluded from the pass-through set:
# keeping them would let a raw id of ".." (or embedded "..") sanitize to
# itself, defeating the very traversal protection this function exists for.
alert_sanitize_id() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-64
}

alert_num() {
  case "$1" in
    '' | *[!0-9]*) printf '%s' "$2" ;;
    *)             printf '%s' "$1" ;;
  esac
}

alert_resolve_sound() {
  if [ -n "${CLAUDE_ALERT_SOUND:-}" ]; then
    if [ -r "$CLAUDE_ALERT_SOUND" ]; then
      printf '%s' "$CLAUDE_ALERT_SOUND"
      return 0
    fi
    alert_log "CLAUDE_ALERT_SOUND is set but not readable: $CLAUDE_ALERT_SOUND"
    return 1
  fi

  local home_dir="${CLAUDE_ALERT_HOME:-$HOME/.claude}" ext
  for ext in wav mp3 aiff aif m4a caf; do
    if [ -r "$home_dir/alert-sound.$ext" ]; then
      printf '%s' "$home_dir/alert-sound.$ext"
      return 0
    fi
  done

  if [ -r /System/Library/Sounds/Submarine.aiff ]; then
    printf '%s' /System/Library/Sounds/Submarine.aiff
    return 0
  fi
  return 1
}

alert_player() {
  if [ -n "${CLAUDE_ALERT_PLAYER:-}" ]; then
    printf '%s' "$CLAUDE_ALERT_PLAYER"
    return 0
  fi
  local p
  case "$(uname -s)" in
    Darwin)
      command -v afplay >/dev/null 2>&1 && { printf 'afplay'; return 0; }
      ;;
    Linux)
      for p in paplay aplay ffplay; do
        command -v "$p" >/dev/null 2>&1 && { printf '%s' "$p"; return 0; }
      done
      ;;
  esac
  return 1
}

alert_play() {
  local sound="$1" player
  player="$(alert_player)" || { alert_log "no audio player available"; return 1; }
  case "$(basename "$player")" in
    ffplay) "$player" -nodisp -autoexit -loglevel quiet "$sound" >/dev/null 2>&1 ;;
    *)      "$player" "$sound" >/dev/null 2>&1 ;;
  esac
}
