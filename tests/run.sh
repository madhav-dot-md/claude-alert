#!/usr/bin/env bash
# claude-alert test suite. No framework, no dependencies.
# Usage: bash tests/run.sh [name-filter]
set -u

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TESTS_DIR/.." && pwd)"
SCRIPTS="$REPO_ROOT/plugins/claude-alert/scripts"
FILTER="${1:-}"

# Captured once, before any test points TMPDIR at a sandbox that later gets
# rm -rf'd. Every setup() after the first must still hand mktemp a real,
# existing parent — GNU mktemp (unlike BSD mktemp) fails outright when
# TMPDIR points at a deleted directory, and with no set -e that failure
# would otherwise go unnoticed and leave the harness operating on
# ${TMPDIR:-/tmp} for real, i.e. the user's actual state dir.
ORIG_TMPDIR="${TMPDIR:-/tmp}"

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
  SANDBOX="$(mktemp -d "$ORIG_TMPDIR/claude-alert-test.XXXXXX")"
  if [ -z "$SANDBOX" ] || [ ! -d "$SANDBOX" ]; then
    printf 'FATAL: mktemp -d failed to produce a sandbox directory — refusing to run tests against real state\n' >&2
    exit 1
  fi
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

state_dir() { printf '%s/claude-alert-%s' "$TMPDIR" "$(id -u)"; } # mirrors lib.sh's alert_state_dir

# --- lib.sh --------------------------------------------------------------

test_json_field_extracts_session_id() {
  # shellcheck source=plugins/claude-alert/scripts/lib.sh
  . "$SCRIPTS/lib.sh"
  local json='{"session_id":"abc-123","hook_event_name":"Notification"}'
  assert_eq "abc-123" "$(alert_json_field session_id "$json")" "extracts session_id"
  assert_eq "" "$(alert_json_field nope "$json")" "missing field yields empty"
  assert_eq "" "$(alert_json_field session_id 'not json at all')" "garbage yields empty"
}

test_sanitize_id_is_filename_safe() {
  # shellcheck source=plugins/claude-alert/scripts/lib.sh
  . "$SCRIPTS/lib.sh"
  assert_eq "abc-123" "$(alert_sanitize_id 'abc-123')" "passes clean id through"
  assert_eq "___etc_passwd" "$(alert_sanitize_id '../etc/passwd')" "neutralises path traversal"
  local long
  long="$(alert_sanitize_id "$(printf 'a%.0s' $(seq 1 200))")"
  assert_eq "64" "${#long}" "truncates to 64 characters"
}

test_num_coerces_bad_values() {
  # shellcheck source=plugins/claude-alert/scripts/lib.sh
  . "$SCRIPTS/lib.sh"
  assert_eq "7" "$(alert_num 7 20)" "keeps a valid number"
  assert_eq "20" "$(alert_num '' 20)" "empty falls back"
  assert_eq "20" "$(alert_num 'abc' 20)" "non-numeric falls back"
  assert_eq "20" "$(alert_num '5; rm -rf /' 20)" "injection attempt falls back"
}

test_resolve_sound_precedence() {
  # shellcheck source=plugins/claude-alert/scripts/lib.sh
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
  # shellcheck source=plugins/claude-alert/scripts/lib.sh
  . "$SCRIPTS/lib.sh"
  rm -f "$CLAUDE_ALERT_HOME"/alert-sound.*
  if [ -r /System/Library/Sounds/Submarine.aiff ]; then
    assert_eq "/System/Library/Sounds/Submarine.aiff" "$(alert_resolve_sound)" "falls back to system sound"
  else
    assert_not_ok "alert_resolve_sound" "returns failure with no sound anywhere"
  fi
}

test_play_invokes_the_player() {
  # shellcheck source=plugins/claude-alert/scripts/lib.sh
  . "$SCRIPTS/lib.sh"
  alert_play "$CLAUDE_ALERT_HOME/alert-sound.wav"
  assert_eq "1" "$(play_count)" "player invoked exactly once"
}

test_log_never_fails() {
  # shellcheck source=plugins/claude-alert/scripts/lib.sh
  . "$SCRIPTS/lib.sh"
  assert_ok "alert_log 'hello'" "log succeeds"
  local logfile; logfile="$(alert_state_dir)/alert.log"
  assert_ok "[ -f '$logfile' ]" "log file created"
}

test_state_dir_is_namespaced_by_uid() {
  # shellcheck source=plugins/claude-alert/scripts/lib.sh
  . "$SCRIPTS/lib.sh"
  assert_eq "$TMPDIR/claude-alert-$(id -u)" "$(alert_state_dir)" \
    "state dir is namespaced by the caller's uid, not shared across users"
}

test_state_dir_refuses_a_preexisting_symlink() {
  # A shared TMPDIR fallback (TMPDIR unset) means another local user could
  # pre-plant a symlink at our uid-namespaced path before we ever run.
  # alert_safe_state_dir must refuse to follow it rather than logging or
  # writing pidfiles through it.
  # shellcheck source=plugins/claude-alert/scripts/lib.sh
  . "$SCRIPTS/lib.sh"
  local target dir
  target="$SANDBOX/symlink-target"
  dir="$(alert_state_dir)"
  mkdir -p "$target" "$(dirname "$dir")"
  ln -s "$target" "$dir"
  assert_not_ok "alert_safe_state_dir create" "refuses a pre-existing symlink"
  alert_log "must not land inside the symlink target"
  assert_ok "[ ! -e '$target/alert.log' ]" "does not write through the symlinked state dir"
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
  local pidfile; pidfile="$(state_dir)/loop.pid"
  mkdir -p "$(state_dir)"
  "$SCRIPTS/alert-loop.sh" "$CLAUDE_ALERT_HOME/alert-sound.wav" 1 0 "$pidfile"
  assert_ok "[ ! -f '$pidfile' ]" "pidfile removed on normal exit"
}

test_loop_stops_when_terminated() {
  local pidfile; pidfile="$(state_dir)/loop.pid"
  mkdir -p "$(state_dir)"
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
  local pidfile; pidfile="$(state_dir)/loop.pid"
  local player_pidfile="$SANDBOX/player.pid"
  mkdir -p "$(state_dir)"
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
run_test test_state_dir_is_namespaced_by_uid
run_test test_state_dir_refuses_a_preexisting_symlink
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
pidfile_for() { printf '%s/%s.pid' "$(state_dir)" "$1"; }

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

test_start_degrades_to_single_play_when_state_dir_is_unsafe() {
  export CLAUDE_ALERT_INTERVAL=1 CLAUDE_ALERT_MAX=50
  local target dir
  target="$SANDBOX/symlink-target"
  dir="$(state_dir)"
  mkdir -p "$target" "$(dirname "$dir")"
  ln -s "$target" "$dir"
  start_loop sess-symlink
  sleep 0.5
  assert_eq "1" "$(play_count)" "still plays once when the state dir is unsafe to use"
  assert_ok "[ ! -e '$target/sess-symlink.pid' ]" "no pidfile written into the symlinked target"
}

# Copies the real scripts into a scratch dir so a test can patch lib.sh's
# behaviour (e.g. force alert_player or alert_sanitize_id to fail) while
# still exercising the real alert-start.sh code path around it, rather than
# reimplementing that logic in the test.
make_patched_scripts() {
  local dir="$SANDBOX/patched-scripts-$RANDOM"
  mkdir -p "$dir"
  cp "$SCRIPTS"/*.sh "$dir/"
  chmod +x "$dir"/*.sh
  printf '%s' "$dir"
}

test_start_does_not_arm_when_no_player_is_available() {
  local patched; patched="$(make_patched_scripts)"
  printf 'alert_player() { return 1; }\n' >> "$patched/lib.sh"
  printf '{"session_id":"sess-noplayer","hook_event_name":"Notification"}' \
    | "$patched/alert-start.sh" --loop
  sleep 0.5
  assert_eq "0" "$(play_count)" "nothing played when no player is available"
  assert_ok "[ ! -f '$(pidfile_for sess-noplayer)' ]" \
    "loop is never armed when no player is available, instead of running the full repeat cap"
}

test_start_refuses_to_arm_when_session_id_sanitises_to_empty() {
  # A non-empty raw session_id that sanitises to empty can only happen if
  # the sanitiser itself misbehaves (e.g. the illegal-byte-sequence bug that
  # LC_ALL=C now closes). Reproduce that failure mode directly to prove
  # alert-start.sh's post-sanitise guard — not just the sanitiser — is what
  # stops it from arming.
  local patched; patched="$(make_patched_scripts)"
  printf 'alert_sanitize_id() { printf "%%s" ""; }\n' >> "$patched/lib.sh"
  printf '{"session_id":"sess-broken","hook_event_name":"Notification"}' \
    | "$patched/alert-start.sh" --loop
  sleep 0.5
  assert_eq "0" "$(play_count)" "nothing played when the sanitised id is empty"
  assert_ok "! ls '$(state_dir)'/*.pid >/dev/null 2>&1" "no pidfile armed when the sanitised id is empty"
}

run_test test_start_arms_and_stop_disarms
run_test test_sessions_are_independent
run_test test_restarting_does_not_stack_alarms
run_test test_once_plays_a_single_time_and_leaves_no_pidfile
run_test test_disable_suppresses_everything
run_test test_malformed_input_is_ignored_without_error
run_test test_missing_sound_never_breaks_the_hook
run_test test_stop_is_a_noop_when_nothing_is_armed
run_test test_start_degrades_to_single_play_when_state_dir_is_unsafe
run_test test_start_does_not_arm_when_no_player_is_available
run_test test_start_refuses_to_arm_when_session_id_sanitises_to_empty

# --- manifests -----------------------------------------------------------

json_ok() { # path — validates syntax without requiring jq
  if command -v jq >/dev/null 2>&1; then
    jq empty "$1" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null
  else
    printf 'SKIP: no json validator available\n' >&2
    return 0
  fi
}

test_manifests_are_valid_json() {
  assert_ok "json_ok '$REPO_ROOT/.claude-plugin/marketplace.json'" "marketplace.json parses"
  assert_ok "json_ok '$REPO_ROOT/plugins/claude-alert/.claude-plugin/plugin.json'" "plugin.json parses"
  assert_ok "json_ok '$REPO_ROOT/plugins/claude-alert/hooks/hooks.json'" "hooks.json parses"
}

test_hooks_reference_scripts_that_exist() {
  local hooks="$REPO_ROOT/plugins/claude-alert/hooks/hooks.json" name
  for name in alert-start.sh alert-stop.sh; do
    assert_ok "grep -q '$name' '$hooks'" "hooks.json references $name"
    assert_ok "[ -x '$SCRIPTS/$name' ]" "$name exists and is executable"
  done
  assert_ok "[ -x '$SCRIPTS/alert-loop.sh' ]" "alert-loop.sh exists and is executable"
}

test_marketplace_points_at_the_plugin() {
  local mk="$REPO_ROOT/.claude-plugin/marketplace.json"
  assert_ok "grep -q '\"neel-tools\"' '$mk'" "marketplace name is neel-tools"
  assert_ok "grep -q '\"./plugins/claude-alert\"' '$mk'" "source path points at the plugin"
  assert_ok "[ -f '$REPO_ROOT/plugins/claude-alert/.claude-plugin/plugin.json' ]" "source path resolves"
}

test_every_notification_type_is_wired() {
  local hooks="$REPO_ROOT/plugins/claude-alert/hooks/hooks.json" t
  for t in permission_prompt idle_prompt agent_needs_input agent_completed; do
    assert_ok "grep -q '$t' '$hooks'" "$t is wired"
  done
  for t in UserPromptSubmit PostToolUse PostToolUseFailure PostToolBatch PermissionDenied SessionEnd Stop; do
    assert_ok "grep -q '\"$t\"' '$hooks'" "$t disarm is wired"
  done
  # The highest-cost value in the whole manifest: if agent_completed or
  # idle_prompt were ever wired to --loop instead of --once, a completed
  # task or a background-command wait would start a five-minute repeating
  # alarm instead of playing one sound.
  assert_ok "grep -A 4 '\"matcher\": \"idle_prompt|agent_completed\"' '$hooks' | grep -q -- '--once'" \
    "idle_prompt and agent_completed's hook command uses --once, not --loop"
  assert_ok "grep -A 4 '\"matcher\": \"permission_prompt|agent_needs_input\"' '$hooks' | grep -q -- '--loop'" \
    "the --loop matcher carries permission_prompt and agent_needs_input, not idle_prompt"
}

run_test test_manifests_are_valid_json
run_test test_hooks_reference_scripts_that_exist
run_test test_marketplace_points_at_the_plugin
run_test test_every_notification_type_is_wired

# --- /alert-test ---------------------------------------------------------

test_alert_test_reports_the_resolved_sound() {
  local out; out="$("$SCRIPTS/alert-test.sh")"
  assert_ok "printf '%s' \"\$(printf '%s' '$out')\" | grep -q 'sound=$CLAUDE_ALERT_HOME/alert-sound.wav'" "reports the resolved sound"
  assert_ok "printf '%s' '$out' | grep -q 'result=ok'" "reports success"
  assert_eq "1" "$(play_count)" "played exactly once"
}

test_alert_test_is_helpful_when_no_sound_is_installed() {
  rm -f "$CLAUDE_ALERT_HOME"/alert-sound.*
  export CLAUDE_ALERT_SOUND="$SANDBOX/nope.wav"
  local out; out="$("$SCRIPTS/alert-test.sh")"
  assert_ok "printf '%s' '$out' | grep -q 'result=no-sound'" "reports the missing sound"
  assert_ok "printf '%s' '$out' | grep -q 'alert-sound.wav'" "names where to put a file"
  assert_eq "0" "$(play_count)" "nothing played"
}

run_test test_alert_test_reports_the_resolved_sound
run_test test_alert_test_is_helpful_when_no_sound_is_installed

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
