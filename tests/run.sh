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

# --- alert-loop.sh -------------------------------------------------------

wait_for_file() { # path timeout-tenths
  local i=0
  while [ "$i" -lt "${2:-30}" ]; do
    [ -e "$1" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_loop_honours_the_repeat_cap() {
  local sound="$CLAUDE_ALERT_HOME/alert-sound.wav"
  "$SCRIPTS/alert-loop.sh" "$sound" 3 0
  assert_eq "3" "$(play_count)" "plays exactly max times then exits"
}

test_loop_writes_and_removes_its_pidfile() {
  local pidfile="$TMPDIR/claude-alert/loop.pid"
  mkdir -p "$TMPDIR/claude-alert"
  "$SCRIPTS/alert-loop.sh" "$CLAUDE_ALERT_HOME/alert-sound.wav" 1 0 "$pidfile"
  assert_ok "[ ! -f '$pidfile' ]" "pidfile removed on normal exit"
}

test_loop_stops_when_terminated() {
  local pidfile="$TMPDIR/claude-alert/loop.pid"
  mkdir -p "$TMPDIR/claude-alert"
  "$SCRIPTS/alert-loop.sh" "$CLAUDE_ALERT_HOME/alert-sound.wav" 50 1 "$pidfile" &
  wait_for_file "$pidfile" 30
  local pid; pid="$(cat "$pidfile")"
  kill -TERM "$pid" 2>/dev/null
  sleep 0.5
  assert_not_ok "kill -0 '$pid'" "loop is gone after TERM"
  assert_ok "[ ! -f '$pidfile' ]" "pidfile cleaned up after TERM"
  local before; before="$(play_count)"
  sleep 1.5
  assert_eq "$before" "$(play_count)" "no further playbacks after TERM"
}

test_loop_kills_inflight_player_on_term() {
  # Guards against a specific regression: if alert-loop.sh backgrounds a
  # wrapper (e.g. `alert_play "$sound" &`) instead of the player process
  # itself, TERM kills the wrapper but the real player is orphaned and
  # keeps playing to completion. play_count alone can't see this — it only
  # ever counts *completed* playbacks — so this test holds a handle on the
  # fake player's own PID and asserts that process is actually gone.
  local pidfile="$TMPDIR/claude-alert/loop.pid"
  local player_pidfile="$SANDBOX/player.pid"
  mkdir -p "$TMPDIR/claude-alert"
  FAKE_PLAYER_SLEEP=2 FAKE_PLAYER_PID_FILE="$player_pidfile" \
    "$SCRIPTS/alert-loop.sh" "$CLAUDE_ALERT_HOME/alert-sound.wav" 50 1 "$pidfile" &
  wait_for_file "$pidfile" 30
  wait_for_file "$player_pidfile" 30
  local loop_pid; loop_pid="$(cat "$pidfile")"
  local player_pid; player_pid="$(cat "$player_pidfile")"
  kill -TERM "$loop_pid" 2>/dev/null
  sleep 0.5
  assert_not_ok "kill -0 '$player_pid'" "in-flight player is killed by TERM, not orphaned"
}

run_test test_json_field_extracts_session_id
run_test test_sanitize_id_is_filename_safe
run_test test_num_coerces_bad_values
run_test test_resolve_sound_precedence
run_test test_resolve_sound_fails_when_nothing_available
run_test test_play_invokes_the_player
run_test test_log_never_fails
run_test test_loop_honours_the_repeat_cap
run_test test_loop_writes_and_removes_its_pidfile
run_test test_loop_stops_when_terminated
run_test test_loop_kills_inflight_player_on_term

# --- alert-start.sh / alert-stop.sh --------------------------------------

start_loop() { # session
  printf '{"session_id":"%s","hook_event_name":"Notification"}' "$1" | "$SCRIPTS/alert-start.sh" --loop
}
start_once() { # session
  printf '{"session_id":"%s","hook_event_name":"Notification"}' "$1" | "$SCRIPTS/alert-start.sh" --once
}
send_stop() { # session
  printf '{"session_id":"%s","hook_event_name":"PostToolUse"}' "$1" | "$SCRIPTS/alert-stop.sh"
}
pidfile_for() { printf '%s/claude-alert/%s.pid' "$TMPDIR" "$1"; }

test_start_arms_and_stop_disarms() {
  export CLAUDE_ALERT_INTERVAL=1 CLAUDE_ALERT_MAX=50
  start_loop sess-a
  assert_ok "wait_for_file '$(pidfile_for sess-a)' 30" "start writes a pidfile"
  local pid; pid="$(cat "$(pidfile_for sess-a)")"
  send_stop sess-a
  sleep 0.5
  assert_not_ok "kill -0 '$pid'" "stop kills the looper"
  assert_ok "[ ! -f '$(pidfile_for sess-a)' ]" "stop clears the pidfile"
}

test_sessions_are_independent() {
  export CLAUDE_ALERT_INTERVAL=1 CLAUDE_ALERT_MAX=50
  start_loop sess-a
  start_loop sess-b
  wait_for_file "$(pidfile_for sess-a)" 30
  wait_for_file "$(pidfile_for sess-b)" 30
  local pid_b; pid_b="$(cat "$(pidfile_for sess-b)")"
  send_stop sess-a
  sleep 0.5
  assert_ok "kill -0 '$pid_b'" "stopping session a leaves session b running"
  send_stop sess-b
}

test_restarting_does_not_stack_alarms() {
  export CLAUDE_ALERT_INTERVAL=1 CLAUDE_ALERT_MAX=50
  start_loop sess-a
  wait_for_file "$(pidfile_for sess-a)" 30
  local first; first="$(cat "$(pidfile_for sess-a)")"
  start_loop sess-a
  sleep 0.5
  assert_not_ok "kill -0 '$first'" "the previous looper was killed"
  local second; second="$(cat "$(pidfile_for sess-a)")"
  assert_ok "kill -0 '$second'" "exactly one looper remains"
  send_stop sess-a
}

test_once_plays_a_single_time_and_leaves_no_pidfile() {
  start_once sess-c
  sleep 0.5
  assert_eq "1" "$(play_count)" "played once"
  assert_ok "[ ! -f '$(pidfile_for sess-c)' ]" "no pidfile for a one-shot"
}

test_disable_suppresses_everything() {
  export CLAUDE_ALERT_DISABLE=1
  start_loop sess-d
  sleep 0.5
  assert_eq "0" "$(play_count)" "nothing played"
  assert_ok "[ ! -f '$(pidfile_for sess-d)' ]" "nothing armed"
}

test_malformed_input_is_ignored_without_error() {
  assert_ok "printf 'not json' | '$SCRIPTS/alert-start.sh' --loop" "start exits 0 on garbage"
  assert_ok "printf '' | '$SCRIPTS/alert-start.sh' --loop" "start exits 0 on empty stdin"
  assert_ok "printf 'not json' | '$SCRIPTS/alert-stop.sh'" "stop exits 0 on garbage"
  assert_eq "0" "$(play_count)" "nothing played from malformed input"
}

test_missing_sound_never_breaks_the_hook() {
  rm -f "$CLAUDE_ALERT_HOME"/alert-sound.*
  export CLAUDE_ALERT_SOUND="$SANDBOX/does-not-exist.wav"
  assert_ok "start_loop sess-e" "start exits 0 with no resolvable sound"
  assert_ok "[ ! -f '$(pidfile_for sess-e)' ]" "nothing armed with no sound"
}

test_stop_is_a_noop_when_nothing_is_armed() {
  assert_ok "send_stop sess-none" "stop exits 0 with no alarm armed"
}

run_test test_start_arms_and_stop_disarms
run_test test_sessions_are_independent
run_test test_restarting_does_not_stack_alarms
run_test test_once_plays_a_single_time_and_leaves_no_pidfile
run_test test_disable_suppresses_everything
run_test test_malformed_input_is_ignored_without_error
run_test test_missing_sound_never_breaks_the_hook
run_test test_stop_is_a_noop_when_nothing_is_armed

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
