# claude-alert Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Claude Code plugin that plays the user's own sound file, on a repeating loop, whenever Claude Code needs attention — and stops the moment they come back.

**Architecture:** Claude Code's `Notification` hook fires with a matcher on notification type (`permission_prompt`, `idle_prompt`, `agent_needs_input`, `agent_completed`). `alert-start.sh` spawns a detached `alert-loop.sh` and records its PID under a session-keyed state file. Four disarm hooks run `alert-stop.sh`, which kills that PID. A hard repeat cap in the loop guarantees no runaway alarm if a disarm event never arrives. The repo doubles as its own plugin marketplace for GitHub distribution.

**Tech Stack:** POSIX-ish bash (no framework, no runtime dependencies), `afplay` on macOS, GitHub Actions for CI.

**Spec:** `docs/superpowers/specs/2026-08-10-claude-alert-plugin-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- **Never block a Claude Code session.** Every hook-invoked script exits `0` on every path, including every error path. No `set -e` in hook entry points.
- **Zero runtime dependencies.** No `jq`, no `python3`, no test framework. macOS ships none of them reliably. `jq` may be *used* when present but never *required*.
- **Repo root:** `~/Projects/claude-alert`. Git is already initialised on branch `main` with two commits.
- **Repository:** `https://github.com/madhav-dot-md/claude-alert`
- **Marketplace name:** `neel-tools` — public, baked into every user's install, do not change.
- **Plugin name:** `claude-alert`. **Version:** `0.1.0`. **License:** MIT.
- **Author block** (identical in `plugin.json` and `marketplace.json`): `{ "name": "Neel Madhav", "url": "https://github.com/madhav-dot-md" }`. No email — these are public files.
- **Bundle no audio.** The fallback is the stock `/System/Library/Sounds/Submarine.aiff`.
- **Commit trailer** on every commit:
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  ```
- **Two test seams beyond the spec's tunables**, both env vars read only by `lib.sh`:
  - `CLAUDE_ALERT_HOME` — overrides `~/.claude` when resolving `alert-sound.*`, so tests never touch the real home directory.
  - `CLAUDE_ALERT_PLAYER` — already in the spec; the tests point it at a fake recorder so the suite is silent.

## File Structure

| File | Responsibility |
| --- | --- |
| `plugins/claude-alert/scripts/lib.sh` | Pure helpers, sourced by every script: stdin-JSON field extraction, id sanitising, numeric coercion, state paths, sound resolution, player dispatch, logging. No top-level side effects. |
| `plugins/claude-alert/scripts/alert-start.sh` | `Notification` hook entry. Parses stdin, cancels any existing alarm for the session, spawns the loop detached, exits immediately. |
| `plugins/claude-alert/scripts/alert-loop.sh` | The detached alarm. Play → sleep → repeat, bounded by the cap. Owns its own PID file. Silences its player child on `TERM`. |
| `plugins/claude-alert/scripts/alert-stop.sh` | Disarm hook entry for four events. Must be cheap — `PostToolUse` fires on every tool call. |
| `plugins/claude-alert/scripts/alert-test.sh` | Diagnostic: prints resolved sound, player and tunables, then plays once. |
| `plugins/claude-alert/commands/alert-test.md` | `/alert-test` slash command wrapping the above. |
| `plugins/claude-alert/hooks/hooks.json` | Wires 2 `Notification` matchers + 4 disarm events to the scripts. |
| `plugins/claude-alert/.claude-plugin/plugin.json` | Plugin manifest. |
| `.claude-plugin/marketplace.json` | Marketplace catalog listing the one plugin. |
| `tests/helpers/fake-player.sh` | Test double for `afplay`; appends to a log instead of making noise. |
| `tests/run.sh` | The whole suite: assert helpers, per-test sandbox, test functions, summary. |
| `.github/workflows/ci.yml` | shellcheck + JSON validation + suite. |
| `README.md` / `LICENSE` / `.gitignore` | Install docs, MIT, ignore rules. |

Splitting `start` / `loop` / `stop` is not ceremony: they run as three different processes with three different lifetimes, and only the loop is long-lived.

---

### Task 1: Test harness and `lib.sh`

**Files:**
- Create: `plugins/claude-alert/scripts/lib.sh`
- Create: `tests/helpers/fake-player.sh`
- Create: `tests/run.sh`

**Interfaces:**
- Consumes: nothing.
- Produces, all sourced from `lib.sh`:
  - `alert_state_dir` → prints `${TMPDIR:-/tmp}/claude-alert`
  - `alert_log <msg...>` → appends a UTC-timestamped line to `<state_dir>/alert.log`; never fails
  - `alert_json_field <field> <json>` → prints the flat top-level string value, or empty
  - `alert_sanitize_id <raw>` → prints a filename-safe id (≤64 chars, `[A-Za-z0-9._-]` only)
  - `alert_num <value> <default>` → prints `<value>` if all-digits, else `<default>`
  - `alert_resolve_sound` → prints a readable sound path, or returns 1
  - `alert_player` → prints the player command, or returns 1
  - `alert_play <sound>` → plays once; returns non-zero on failure

- [ ] **Step 1: Write the failing tests**

Create `tests/run.sh`:

```bash
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
```

Create `tests/helpers/fake-player.sh`:

```bash
#!/usr/bin/env bash
# Test double for afplay. Records the invocation instead of making noise.
printf 'play %s\n' "$*" >> "${FAKE_PLAYER_LOG:?FAKE_PLAYER_LOG must be set}"
exit 0
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd ~/Projects/claude-alert
chmod +x tests/run.sh tests/helpers/fake-player.sh
bash tests/run.sh
```

Expected: FAIL — `lib.sh: No such file or directory`.

- [ ] **Step 3: Write `plugins/claude-alert/scripts/lib.sh`**

```bash
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
# state directory.
alert_sanitize_id() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-64
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
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd ~/Projects/claude-alert && bash tests/run.sh
```

Expected: `20 passed, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/claude-alert
git add plugins/claude-alert/scripts/lib.sh tests/
git commit -m "$(cat <<'EOF'
feat: add lib.sh helpers and dependency-free test harness

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `alert-loop.sh` — the bounded alarm

**Files:**
- Create: `plugins/claude-alert/scripts/alert-loop.sh`
- Modify: `tests/run.sh` (append test functions + `run_test` lines before the summary block)

**Interfaces:**
- Consumes: `alert_play`, `alert_log` from Task 1.
- Produces: `alert-loop.sh <sound> <max-repeats> <interval-seconds> [pidfile]`. Writes its own PID to `pidfile` on start and removes it on exit — **only if the file still contains its own PID**, so a newer alarm's file is never deleted. Exits 0 always.

The loop owning its own PID file (rather than the caller writing it) is what lets `alert-start.sh` spawn it double-forked, detached from the hook's process group.

- [ ] **Step 1: Write the failing tests**

Insert these into `tests/run.sh`, immediately after `test_log_never_fails`:

```bash
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
```

And add these `run_test` lines before the `printf '\n%s passed` summary:

```bash
run_test test_loop_honours_the_repeat_cap
run_test test_loop_writes_and_removes_its_pidfile
run_test test_loop_stops_when_terminated
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd ~/Projects/claude-alert && bash tests/run.sh loop
```

Expected: FAIL — `alert-loop.sh: No such file or directory`.

- [ ] **Step 3: Write `plugins/claude-alert/scripts/alert-loop.sh`**

```bash
#!/usr/bin/env bash
# The detached alarm. Not invoked by hooks directly — alert-start.sh spawns it.
# Usage: alert-loop.sh <sound> <max-repeats> <interval-seconds> [pidfile]
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

SOUND="${1:-}"
MAX="$(alert_num "${2:-}" 15)"
INTERVAL="$(alert_num "${3:-}" 20)"
PIDFILE="${4:-}"
CHILD=""

[ -n "$SOUND" ] || exit 0

if [ -n "$PIDFILE" ]; then
  printf '%s' "$$" > "$PIDFILE" 2>/dev/null || PIDFILE=""
fi

cleanup() {
  # Silence whatever is playing right now rather than letting it finish.
  [ -n "$CHILD" ] && kill -TERM "$CHILD" 2>/dev/null
  # Only remove the pidfile if it is still ours; a newer alarm may own it.
  if [ -n "$PIDFILE" ] && [ -f "$PIDFILE" ] && [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ]; then
    rm -f "$PIDFILE"
  fi
}
trap 'cleanup; exit 0' TERM INT
trap cleanup EXIT

i=0
while [ "$i" -lt "$MAX" ]; do
  alert_play "$SOUND" & CHILD=$!
  wait "$CHILD" 2>/dev/null
  CHILD=""
  i=$((i + 1))
  [ "$i" -lt "$MAX" ] || break
  sleep "$INTERVAL" & CHILD=$!
  wait "$CHILD" 2>/dev/null
  CHILD=""
done
exit 0
```

Backgrounding the player and `wait`ing on it — rather than calling it directly — is what makes the `TERM` trap able to interrupt playback mid-sound.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd ~/Projects/claude-alert && chmod +x plugins/claude-alert/scripts/alert-loop.sh && bash tests/run.sh
```

Expected: all tests pass, exit 0.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/claude-alert
git add plugins/claude-alert/scripts/alert-loop.sh tests/run.sh
git commit -m "$(cat <<'EOF'
feat: add bounded alarm loop with clean termination

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `alert-start.sh` and `alert-stop.sh` — the hook entry points

**Files:**
- Create: `plugins/claude-alert/scripts/alert-start.sh`
- Create: `plugins/claude-alert/scripts/alert-stop.sh`
- Modify: `plugins/claude-alert/scripts/lib.sh` (append `alert_kill_pidfile`)
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: everything from Tasks 1 and 2.
- Produces:
  - `alert_kill_pidfile <pidfile>` in `lib.sh` — TERMs the recorded PID and removes the file; tolerates a missing, stale or malformed file. Always returns 0.
  - `alert-start.sh --loop | --once`, reading the hook JSON on stdin.
  - `alert-stop.sh`, reading the hook JSON on stdin.

- [ ] **Step 1: Write the failing tests**

Insert into `tests/run.sh` after the loop tests:

```bash
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
```

Add before the summary block:

```bash
run_test test_start_arms_and_stop_disarms
run_test test_sessions_are_independent
run_test test_restarting_does_not_stack_alarms
run_test test_once_plays_a_single_time_and_leaves_no_pidfile
run_test test_disable_suppresses_everything
run_test test_malformed_input_is_ignored_without_error
run_test test_missing_sound_never_breaks_the_hook
run_test test_stop_is_a_noop_when_nothing_is_armed
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd ~/Projects/claude-alert && bash tests/run.sh
```

Expected: FAIL — `alert-start.sh: No such file or directory`.

- [ ] **Step 3a: Append `alert_kill_pidfile` to `lib.sh`**

```bash
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
```

- [ ] **Step 3b: Write `plugins/claude-alert/scripts/alert-start.sh`**

```bash
#!/usr/bin/env bash
# Notification hook entry point. Arms the alert and returns immediately.
# Usage: alert-start.sh --loop | --once
# Exits 0 on every path: a failure here must never block a Claude Code session.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
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

SOUND="$(alert_resolve_sound)" || { alert_log "start: no sound file resolvable"; exit 0; }

STATE_DIR="$(alert_state_dir)"
INTERVAL="$(alert_num "${CLAUDE_ALERT_INTERVAL:-}" 20)"
MAX="$(alert_num "${CLAUDE_ALERT_MAX:-}" 15)"

# A one-shot needs no state at all.
if [ "$MODE" = "--once" ]; then
  ( nohup "$SCRIPT_DIR/alert-loop.sh" "$SOUND" 1 0 </dev/null >/dev/null 2>&1 & )
  exit 0
fi

if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
  alert_log "start: state dir unwritable, degrading to a single play"
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
```

- [ ] **Step 3c: Write `plugins/claude-alert/scripts/alert-stop.sh`**

```bash
#!/usr/bin/env bash
# Disarm entry point for UserPromptSubmit, PostToolUse, PermissionDenied and
# SessionEnd. PostToolUse fires on every single tool call, so the common path
# — nothing armed — must stay as close to free as possible.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
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
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd ~/Projects/claude-alert
chmod +x plugins/claude-alert/scripts/alert-start.sh plugins/claude-alert/scripts/alert-stop.sh
bash tests/run.sh
```

Expected: all tests pass, exit 0. If `test_restarting_does_not_stack_alarms` is flaky, raise the `wait_for_file` timeout rather than adding a bare `sleep`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/claude-alert
git add plugins/claude-alert/scripts/ tests/run.sh
git commit -m "$(cat <<'EOF'
feat: add arm/disarm hook entry points

Session-keyed state so concurrent Claude Code windows do not cancel each
other's alarms. Every path exits 0.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Plugin and marketplace manifests

**Files:**
- Create: `plugins/claude-alert/hooks/hooks.json`
- Create: `plugins/claude-alert/.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: the four script paths from Tasks 1–3.
- Produces: an installable plugin. `${CLAUDE_PLUGIN_ROOT}` expands to `plugins/claude-alert/` at hook time.

- [ ] **Step 1: Write the failing tests**

Insert into `tests/run.sh` after the start/stop tests:

```bash
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
  for t in UserPromptSubmit PostToolUse PermissionDenied SessionEnd; do
    assert_ok "grep -q '$t' '$hooks'" "$t disarm is wired"
  done
}
```

Add before the summary block:

```bash
run_test test_manifests_are_valid_json
run_test test_hooks_reference_scripts_that_exist
run_test test_marketplace_points_at_the_plugin
run_test test_every_notification_type_is_wired
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd ~/Projects/claude-alert && bash tests/run.sh manifest
```

Expected: FAIL — the manifest files do not exist.

- [ ] **Step 3a: Write `plugins/claude-alert/hooks/hooks.json`**

```json
{
  "description": "Plays a user-supplied sound when Claude Code needs your attention",
  "hooks": {
    "Notification": [
      {
        "matcher": "permission_prompt|idle_prompt|agent_needs_input",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/alert-start.sh\" --loop",
            "timeout": 5
          }
        ]
      },
      {
        "matcher": "agent_completed",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/alert-start.sh\" --once",
            "timeout": 5
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/alert-stop.sh\"", "timeout": 5 }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/alert-stop.sh\"", "timeout": 5 }
        ]
      }
    ],
    "PermissionDenied": [
      {
        "hooks": [
          { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/alert-stop.sh\"", "timeout": 5 }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/alert-stop.sh\"", "timeout": 5 }
        ]
      }
    ]
  }
}
```

- [ ] **Step 3b: Write `plugins/claude-alert/.claude-plugin/plugin.json`**

```json
{
  "name": "claude-alert",
  "displayName": "Claude Alert",
  "description": "Plays a sound when Claude Code needs your attention, and keeps sounding until you come back",
  "version": "0.1.0",
  "author": { "name": "Neel Madhav", "url": "https://github.com/madhav-dot-md" },
  "homepage": "https://github.com/madhav-dot-md/claude-alert",
  "repository": "https://github.com/madhav-dot-md/claude-alert",
  "license": "MIT",
  "keywords": ["hooks", "notification", "sound", "productivity", "macos"]
}
```

- [ ] **Step 3c: Write `.claude-plugin/marketplace.json`**

```json
{
  "name": "neel-tools",
  "description": "Claude Code plugins by Neel Madhav",
  "owner": { "name": "Neel Madhav", "url": "https://github.com/madhav-dot-md" },
  "plugins": [
    {
      "name": "claude-alert",
      "source": "./plugins/claude-alert",
      "description": "Plays a sound when Claude Code needs your attention, and keeps sounding until you come back",
      "version": "0.1.0",
      "author": { "name": "Neel Madhav", "url": "https://github.com/madhav-dot-md" },
      "homepage": "https://github.com/madhav-dot-md/claude-alert",
      "repository": "https://github.com/madhav-dot-md/claude-alert",
      "license": "MIT",
      "category": "productivity",
      "keywords": ["hooks", "notification", "sound", "productivity", "macos"]
    }
  ]
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd ~/Projects/claude-alert && bash tests/run.sh
```

Expected: all tests pass, exit 0.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/claude-alert
git add .claude-plugin plugins/claude-alert/hooks plugins/claude-alert/.claude-plugin tests/run.sh
git commit -m "$(cat <<'EOF'
feat: add plugin and marketplace manifests

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `/alert-test` diagnostic command

**Files:**
- Create: `plugins/claude-alert/scripts/alert-test.sh`
- Create: `plugins/claude-alert/commands/alert-test.md`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `alert_resolve_sound`, `alert_player`, `alert_play`, `alert_num` from Task 1.
- Produces: `alert-test.sh`, printing `sound=`, `player=`, `interval=`, `max=` and a final `result=` line. Exits 0 always. Machine-greppable so the tests can assert on it.

This exists so "is my sound installed correctly?" is a one-second check rather than something you have to provoke a real permission prompt to find out.

- [ ] **Step 1: Write the failing tests**

Insert into `tests/run.sh` after the manifest tests:

```bash
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
```

Add before the summary block:

```bash
run_test test_alert_test_reports_the_resolved_sound
run_test test_alert_test_is_helpful_when_no_sound_is_installed
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd ~/Projects/claude-alert && bash tests/run.sh alert_test
```

Expected: FAIL — `alert-test.sh: No such file or directory`.

- [ ] **Step 3a: Write `plugins/claude-alert/scripts/alert-test.sh`**

```bash
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
  printf 'searched=$CLAUDE_ALERT_SOUND, %s/alert-sound.{wav,mp3,aiff,aif,m4a,caf}, /System/Library/Sounds/Submarine.aiff\n' "$HOME_DIR"
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
```

- [ ] **Step 3b: Write `plugins/claude-alert/commands/alert-test.md`**

```markdown
---
description: Play the claude-alert sound once and report the resolved configuration
---

Output of the claude-alert self-test:

!`"${CLAUDE_PLUGIN_ROOT}/scripts/alert-test.sh"`

Summarise the above for the user in two or three lines: which sound file was
chosen, which player was used, and whether playback succeeded.

- If `result=no-sound`, tell them to drop a short (1–3 second) sound file at
  `~/.claude/alert-sound.wav` and run `/alert-test` again.
- If `result=no-player`, tell them no audio player was found — `afplay` is
  expected on macOS.
- If `result=ok` but they heard nothing, suggest checking system volume and
  output device.
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd ~/Projects/claude-alert && chmod +x plugins/claude-alert/scripts/alert-test.sh && bash tests/run.sh
```

Expected: all tests pass, exit 0.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/claude-alert
git add plugins/claude-alert/scripts/alert-test.sh plugins/claude-alert/commands tests/run.sh
git commit -m "$(cat <<'EOF'
feat: add /alert-test diagnostic command

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: README, licence and CI

**Files:**
- Create: `README.md`, `LICENSE`, `.gitignore`, `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: the finished plugin from Tasks 1–5.
- Produces: nothing other code depends on.

- [ ] **Step 1: Write `.gitignore`**

```gitignore
.DS_Store
*.log
```

- [ ] **Step 2: Write `LICENSE`**

```
MIT License

Copyright (c) 2026 Neel Madhav

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 3: Write `README.md`**

````markdown
# claude-alert

Plays a sound when Claude Code needs your attention — and keeps sounding until
you come back.

If you look away while Claude works, a permission prompt can sit there silently
for minutes. This plugin makes that impossible to miss.

## Install

```
/plugin marketplace add madhav-dot-md/claude-alert
/plugin install claude-alert@neel-tools
```

Then drop a sound file at `~/.claude/alert-sound.wav` and check it works:

```
/alert-test
```

Keep the sound **short — 1 to 3 seconds**. It repeats every 20 seconds.
`.wav`, `.mp3`, `.aiff`, `.aif`, `.m4a` and `.caf` all work.

If you install no sound of your own, it falls back to the stock macOS
`Submarine` system sound.

## When it sounds

| Moment | Behaviour |
| --- | --- |
| Claude needs permission to run a tool | Repeats until you respond |
| Claude has gone idle at an empty prompt | Repeats until you respond |
| A background subagent is blocked on input | Repeats until you respond |
| A task finishes | Plays once |

The alarm stops the moment you respond — approve or deny a permission, type a
prompt, or end the session. As a backstop it also stops itself after 15
repeats (about 5 minutes), so it can never run away if Claude Code exits
unexpectedly.

## Configuration

All optional environment variables.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CLAUDE_ALERT_SOUND` | unset | Explicit path to the sound file |
| `CLAUDE_ALERT_INTERVAL` | `20` | Seconds between repeats |
| `CLAUDE_ALERT_MAX` | `15` | Maximum repeats before giving up |
| `CLAUDE_ALERT_DISABLE` | unset | Set to `1` to mute without uninstalling |

Set them in the `env` block of `~/.claude/settings.json`:

```json
{ "env": { "CLAUDE_ALERT_INTERVAL": "10", "CLAUDE_ALERT_MAX": "30" } }
```

## Requirements

macOS. Playback uses the built-in `afplay`. On Linux the plugin looks for
`paplay`, `aplay` or `ffplay`, but that path is untested.

No runtime dependencies — it is plain bash.

## Troubleshooting

`/alert-test` prints exactly what was resolved and why. Beyond that, the
plugin logs to `${TMPDIR:-/tmp}/claude-alert/alert.log`.

The plugin never blocks a session: every script exits 0 on every path, so a
misconfiguration makes it silent rather than disruptive.

## Development

```bash
bash tests/run.sh            # the whole suite, silent
bash tests/run.sh loop       # only tests whose name contains "loop"
claude plugin validate .     # manifest check, before pushing
```

Tests replace the audio player with a recorder via `CLAUDE_ALERT_PLAYER`, and
redirect `~/.claude` via `CLAUDE_ALERT_HOME`, so the suite is silent and never
touches your real configuration.

## Licence

MIT
````

- [ ] **Step 4: Write `.github/workflows/ci.yml`**

```yaml
name: ci

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install shellcheck
        run: sudo apt-get update && sudo apt-get install -y shellcheck

      - name: Lint shell scripts
        run: shellcheck plugins/claude-alert/scripts/*.sh tests/*.sh tests/helpers/*.sh

      - name: Validate JSON manifests
        run: |
          for f in .claude-plugin/marketplace.json \
                   plugins/claude-alert/.claude-plugin/plugin.json \
                   plugins/claude-alert/hooks/hooks.json; do
            python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f"
            echo "ok $f"
          done

      - name: Run test suite
        run: bash tests/run.sh
```

CI deliberately does not run `claude plugin validate` — that would make the
build depend on installing the Claude Code CLI. It stays a documented local
pre-push step.

- [ ] **Step 5: Verify locally, then commit**

```bash
cd ~/Projects/claude-alert
command -v shellcheck >/dev/null && shellcheck plugins/claude-alert/scripts/*.sh tests/*.sh tests/helpers/*.sh
bash tests/run.sh
git add README.md LICENSE .gitignore .github
git commit -m "$(cat <<'EOF'
docs: add README, MIT licence and CI workflow

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: shellcheck clean (fix any warnings before committing), all tests pass.

---

### Task 7: Real install, end-to-end verification, and push

**Files:** none created. This is the task that proves the plugin actually works inside Claude Code rather than only in the test harness.

**Interfaces:**
- Consumes: the complete repo.
- Produces: a pushed GitHub repo and a verified local install.

- [ ] **Step 1: Validate the manifests with the real CLI**

```bash
cd ~/Projects/claude-alert && claude plugin validate .
```

Expected: no errors. If `claude plugin validate` is unavailable, note it and continue.

- [ ] **Step 2: Install from the local path and confirm the sound**

In a Claude Code session:

```
/plugin marketplace add ~/Projects/claude-alert
/plugin install claude-alert@neel-tools
```

Put a real sound file at `~/.claude/alert-sound.wav`, restart Claude Code so
the hooks load, then run `/alert-test`. Expected: `result=ok` and an audible
sound.

- [ ] **Step 3: Verify the arm/disarm cycle for real**

Set a short interval for the test so you are not waiting 20 seconds:

```bash
CLAUDE_ALERT_INTERVAL=5 claude
```

Ask Claude to run a command that needs approval. Expected: the sound starts
and repeats every 5 seconds; approving it stops the sound immediately. Then
check the log is clean:

```bash
cat "${TMPDIR:-/tmp}/claude-alert/alert.log"
```

Expected: no errors. Confirm no orphaned loopers survive:

```bash
pgrep -fl alert-loop.sh
ls "${TMPDIR:-/tmp}/claude-alert/"
```

Expected: no processes, no leftover `.pid` files.

- [ ] **Step 4: Push to GitHub**

The repository `https://github.com/madhav-dot-md/claude-alert` must already
exist and be **empty** — no README, no licence, no `.gitignore` — or the first
push will be rejected as a non-fast-forward.

```bash
cd ~/Projects/claude-alert
git remote add origin https://github.com/madhav-dot-md/claude-alert.git
git push -u origin main
```

If the remote already has commits, rebase onto it rather than force-pushing:
`git pull --rebase origin main && git push -u origin main`.

- [ ] **Step 5: Verify the public install path**

Remove the local marketplace and re-add it from GitHub, which is what everyone
else will experience:

```
/plugin marketplace remove neel-tools
/plugin marketplace add madhav-dot-md/claude-alert
/plugin install claude-alert@neel-tools
```

Restart Claude Code and run `/alert-test`. Expected: `result=ok`.

- [ ] **Step 6: Commit any fixes found during verification**

```bash
cd ~/Projects/claude-alert
git add -A
git commit -m "$(cat <<'EOF'
fix: address issues found during end-to-end verification

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

Skip this step if verification found nothing.

---

## Notes for the implementer

- **`chmod +x` matters.** Git tracks the executable bit; a script committed
  without it fails for every user who installs the plugin. Task 4 tests assert
  `[ -x ... ]` for exactly this reason.
- **Do not add `set -e` to hook entry points.** Under `set -e`, a failed
  `grep` inside a helper aborts the script mid-way and can leave a stale PID
  file. Return codes are checked explicitly instead.
- **`( nohup … & )` is deliberate.** A bare `nohup … &` survives SIGHUP but
  not the hook's process group being reaped. The subshell double-fork
  reparents the loop.
- **Timing tests are the flakiness risk.** Prefer raising a `wait_for_file`
  timeout over inserting bare `sleep`s.
