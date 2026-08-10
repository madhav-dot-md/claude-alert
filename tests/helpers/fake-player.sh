#!/usr/bin/env bash
# Test double for afplay. Records the invocation instead of making noise.
printf 'play %s\n' "$*" >> "${FAKE_PLAYER_LOG:?FAKE_PLAYER_LOG must be set}"
exit 0
