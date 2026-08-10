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
| Claude needs permission to run a tool | Repeats until the approved command finishes |
| Claude has gone idle at an empty prompt | Repeats until you send a prompt |
| A background subagent is blocked on input | Repeats until the turn ends |
| A task finishes | Plays once |

The alarm stops when the approved command actually finishes running — not the
moment you click approve — or when you type a new prompt, or when the turn
ends. There is no hook at the instant you approve or deny a permission
prompt, so an approved `npm install` keeps ringing for the whole install. As
a backstop it also stops itself after 15 repeats (about 5 minutes), so it can
never run away if Claude Code exits unexpectedly.

## Configuration

All optional environment variables.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CLAUDE_ALERT_SOUND` | unset | Explicit path to the sound file |
| `CLAUDE_ALERT_INTERVAL` | `20` | Seconds between repeats |
| `CLAUDE_ALERT_MAX` | `15` | Maximum repeats before giving up |
| `CLAUDE_ALERT_DISABLE` | unset | Set to `1` to mute without uninstalling |
| `CLAUDE_ALERT_PLAYER` | auto-detected | Explicit playback command, overriding auto-detection |

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
plugin logs to `${TMPDIR:-/tmp}/claude-alert-<your-uid>/alert.log` (run `id -u`
to get your uid, or just `ls ${TMPDIR:-/tmp} | grep claude-alert`).

The plugin never blocks a session: every script exits 0 on every path, so a
misconfiguration makes it silent rather than disruptive.

**Stuck alarm.** The loop is a detached background process, so if Claude Code
is killed (`SIGKILL`) or the terminal window is closed outright, nothing is
left to disarm it and it can keep ringing for up to 5 minutes on its own. To
stop it immediately:

```bash
pkill -f alert-loop.sh
rm -f "${TMPDIR:-/tmp}/claude-alert-$(id -u)"/*.pid
```

## Known limitations

- **macOS only in practice.** The Linux fallback (`paplay`/`aplay`/`ffplay`)
  is in the code but hasn't been exercised on a real Linux machine — see
  [Requirements](#requirements).
- **A disarm can be missed in a very narrow window.** If you respond to a
  prompt in the fraction of a second between the alert being triggered and
  the alarm process registering itself, that specific response won't silence
  it — the alarm then stops at the next thing you do, or at the repeat cap.
  This is a deliberate trade-off: closing that window would mean extra work
  on every single tool call, which isn't worth it to guard against something
  narrower than human reaction time.
- **A subagent alert may share its session id with the parent session.** A
  tool call in the parent session can then silence the subagent's alarm
  early. This fails toward a missed alarm rather than a stuck one.

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
