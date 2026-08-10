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
- If `result=playback-failed`, tell them the sound file and player were both
  found but playback itself failed — likely a corrupted or truncated file, a
  permission error on the file, or a file that isn't actually audio despite
  its extension — and suggest trying a different sound file.
- If `result=ok` but they heard nothing, suggest checking system volume and
  output device.
