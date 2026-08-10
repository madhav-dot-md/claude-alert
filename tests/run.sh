#!/usr/bin/env bash
# claude-alert test suite. No framework, no dependencies.
# Usage: bash tests/run.sh [name-filter]
set -u

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TESTS_DIR/.." && pwd)"
SCRIPTS="$REPO_ROOT/plugins/claude-alert/scripts"
FILTER="${1:-}"

PASS=0
FAIL=0

assert_eq() { # expected actual label
  if [ "$1" = "$2" ]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$3"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$3" "$1" "$2"
  fi
}

assert_ok() { # command-string label
  if eval "$1" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$2"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL %s (expected success: %s)\n' "$2" "$1"
  fi
}

assert_not_ok() { # command-string label
  if eval "$1" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1)); printf '  FAIL %s (expected failure: %s)\n' "$2" "$1"
  else
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$2"
  fi
}

SANDBOX=""
setup() {
  SANDBOX="$(mktemp -d)"
  export TMPDIR="$SANDBOX/tmp"
  export CLAUDE_ALERT_HOME="$SANDBOX/claude"
  export FAKE_PLAYER_LOG="$SANDBOX/player.log"
  export CLAUDE_ALERT_PLAYER="$TESTS_DIR/helpers/fake-player.sh"
  mkdir -p "$TMPDIR" "$CLAUDE_ALERT_HOME"
  : > "$FAKE_PLAYER_LOG"
  printf 'not-real-audio' > "$CLAUDE_ALERT_HOME/alert-sound.wav"
  unset CLAUDE_ALERT_SOUND CLAUDE_ALERT_DISABLE CLAUDE_ALERT_INTERVAL CLAUDE_ALERT_MAX
}

teardown() {
  [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
  SANDBOX=""
}

run_test() {
  case "$1" in *"$FILTER"*) ;; *) return 0 ;; esac
  printf '%s\n' "$1"
  setup
  "$1"
  teardown
}

play_count() { # counts recorded playbacks — one line per playback
  if [ -f "${FAKE_PLAYER_LOG:-}" ]; then
    wc -l < "$FAKE_PLAYER_LOG" | tr -d ' \n'
  else
    printf '0'
  fi
}

# --- lib.sh --------------------------------------------------------------

test_json_field_extracts_session_id() {
  . "$SCRIPTS/lib.sh"
  local json='{"session_id":"abc-123","hook_event_name":"Notification"}'
  assert_eq "abc-123" "$(alert_json_field session_id "$json")" "extracts session_id"
  assert_eq "" "$(alert_json_field nope "$json")" "missing field yields empty"
  assert_eq "" "$(alert_json_field session_id 'not json at all')" "garbage yields empty"
}

test_sanitize_id_is_filename_safe() {
  . "$SCRIPTS/lib.sh"
  assert_eq "abc-123" "$(alert_sanitize_id 'abc-123')" "passes clean id through"
  assert_eq "___etc_passwd" "$(alert_sanitize_id '../etc/passwd')" "neutralises path traversal"
  local long
  long="$(alert_sanitize_id "$(printf 'a%.0s' $(seq 1 200))")"
  assert_eq "64" "${#long}" "truncates to 64 characters"
}

test_num_coerces_bad_values() {
  . "$SCRIPTS/lib.sh"
  assert_eq "7" "$(alert_num 7 20)" "keeps a valid number"
  assert_eq "20" "$(alert_num '' 20)" "empty falls back"
  assert_eq "20" "$(alert_num 'abc' 20)" "non-numeric falls back"
  assert_eq "20" "$(alert_num '5; rm -rf /' 20)" "injection attempt falls back"
}

test_resolve_sound_precedence() {
  . "$SCRIPTS/lib.sh"
  assert_eq "$CLAUDE_ALERT_HOME/alert-sound.wav" "$(alert_resolve_sound)" "finds ~/.claude/alert-sound.wav"

  printf 'x' > "$SANDBOX/explicit.mp3"
  local explicit
  explicit="$(CLAUDE_ALERT_SOUND="$SANDBOX/explicit.mp3" alert_resolve_sound)"
  assert_eq "$SANDBOX/explicit.mp3" "$explicit" "CLAUDE_ALERT_SOUND wins over ~/.claude"

  rm -f "$CLAUDE_ALERT_HOME/alert-sound.wav"
  printf 'x' > "$CLAUDE_ALERT_HOME/alert-sound.aiff"
  assert_eq "$CLAUDE_ALERT_HOME/alert-sound.aiff" "$(alert_resolve_sound)" "falls through to .aiff"
}

test_resolve_sound_fails_when_nothing_available() {
  . "$SCRIPTS/lib.sh"
  rm -f "$CLAUDE_ALERT_HOME"/alert-sound.*
  if [ -r /System/Library/Sounds/Submarine.aiff ]; then
    assert_eq "/System/Library/Sounds/Submarine.aiff" "$(alert_resolve_sound)" "falls back to system sound"
  else
    assert_not_ok "alert_resolve_sound" "returns failure with no sound anywhere"
  fi
}

test_play_invokes_the_player() {
  . "$SCRIPTS/lib.sh"
  alert_play "$CLAUDE_ALERT_HOME/alert-sound.wav"
  assert_eq "1" "$(play_count)" "player invoked exactly once"
}

test_log_never_fails() {
  . "$SCRIPTS/lib.sh"
  assert_ok "alert_log 'hello'" "log succeeds"
  local logfile; logfile="$(alert_state_dir)/alert.log"
  assert_ok "[ -f '$logfile' ]" "log file created"
}

run_test test_json_field_extracts_session_id
run_test test_sanitize_id_is_filename_safe
run_test test_num_coerces_bad_values
run_test test_resolve_sound_precedence
run_test test_resolve_sound_fails_when_nothing_available
run_test test_play_invokes_the_player
run_test test_log_never_fails

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
