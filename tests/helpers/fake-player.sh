#!/usr/bin/env bash
# Test double for afplay. Records the invocation instead of making noise.
# FAKE_PLAYER_PID_FILE, if set, gets this process's own PID written to it
# before the (simulated) playback starts, so a test can hold a real, killable
# handle on "the player" — not just observe the log after the fact.
# FAKE_PLAYER_SLEEP simulates in-flight playback duration; defaults to 0 so
# existing tests stay fast.
[ -n "${FAKE_PLAYER_PID_FILE:-}" ] && printf '%s' "$$" > "$FAKE_PLAYER_PID_FILE"
sleep "${FAKE_PLAYER_SLEEP:-0}"
printf 'play %s\n' "$*" >> "${FAKE_PLAYER_LOG:?FAKE_PLAYER_LOG must be set}"
exit 0
