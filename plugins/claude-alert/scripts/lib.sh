#!/usr/bin/env bash
# Shared helpers for claude-alert. Sourced, never executed directly.
# Nothing here may exit non-zero in a way that escapes to a hook: callers
# check return codes, but a failure must never abort a Claude Code session.

alert_state_dir() {
  printf '%s/claude-alert-%s' "${TMPDIR:-/tmp}" "$(id -u)"
}

# Namespaced by uid so a shared /tmp fallback (TMPDIR unset — Linux,
# containers, launchd/cron, env -i) can't be pre-created by another local
# user. Still refuses a pre-existing symlink or a directory we don't own,
# since a same-uid namespace only helps if we also refuse to follow
# something an attacker planted before we got here.
#
# $1: pass "create" to mkdir -m 700 -p it when missing; otherwise read-only
# (used by the disarm fast path, which must not create state that was never
# armed). Prints the dir on success; prints nothing and returns 1 otherwise.
# Never calls alert_log: alert_log depends on this, and logging a failure to
# obtain a safe log directory would recurse.
alert_safe_state_dir() {
  local dir
  dir="$(alert_state_dir)"
  [ -L "$dir" ] && return 1
  if [ "${1:-}" = create ]; then
    # A tightened umask (rather than `mkdir -m 700 -p`) so every directory
    # -p creates along the way — not just the deepest one — comes out
    # private from the moment it exists, with no window where a
    # default-mode intermediate directory is briefly world-readable.
    ( umask 077 && mkdir -p "$dir" ) 2>/dev/null
  fi
  [ -d "$dir" ] || return 1
  [ -O "$dir" ] || return 1
  printf '%s' "$dir"
  return 0
}

alert_log() {
  local dir
  dir="$(alert_safe_state_dir create)" || return 0
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
  # LC_ALL=C: BSD tr exits 1 and truncates output on an illegal byte
  # sequence under a UTF-8 locale, which would otherwise let a session_id
  # containing invalid UTF-8 collapse to a short or empty string.
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9_-' '_' | cut -c1-64
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

# Replace the current process with the player. ONLY safe inside a subshell —
# in the main shell this would replace the caller.
alert_exec_player() {
  local sound="$1" player
  player="$(alert_player)" || { alert_log "no audio player available"; return 1; }
  case "$(basename "$player")" in
    ffplay) exec "$player" -nodisp -autoexit -loglevel quiet "$sound" >/dev/null 2>&1 ;;
    *)      exec "$player" "$sound" >/dev/null 2>&1 ;;
  esac
}

# Blocking play, safe to call anywhere. The subshell contains the exec, so
# alert_play's own caller is never replaced.
#
# A caller that needs to interrupt playback mid-sound (e.g. alert-loop.sh)
# should background alert_exec_player directly instead of alert_play:
# `alert_exec_player "$sound" & CHILD=$!`. Backgrounding a function call
# forks exactly one subshell, and the exec inside it replaces that subshell
# with the player — so $CHILD is the player's own PID, and `kill -TERM
# "$CHILD"` reaches it directly instead of killing a wrapper and orphaning
# the player underneath it.
alert_play() {
  ( alert_exec_player "$1" )
}

alert_kill_pidfile() {
  local pidfile="$1" pid
  [ -n "$pidfile" ] || return 0
  [ -f "$pidfile" ] || return 0
  pid="$(cat "$pidfile" 2>/dev/null)"
  case "$pid" in
    '' | *[!0-9]*) rm -f "$pidfile"; return 0 ;;
  esac
  kill -TERM "$pid" 2>/dev/null || true
  rm -f "$pidfile" 2>/dev/null || true
  return 0
}
