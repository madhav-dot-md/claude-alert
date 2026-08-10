# claude-alert — design

**Date:** 2026-08-10
**Status:** approved, pending implementation plan

## Problem

While Claude Code works, the user's attention goes elsewhere (phone, another window). Claude
hits a permission prompt and blocks. The prompt is silent, so it sits there — sometimes for
many minutes — until the user happens to glance back. The wasted time is the cost.

The same problem applies at three other moments: Claude going idle at an empty prompt, a
background subagent blocking on input, and a long task finishing without anyone noticing.

## Goal

An audible alarm, using a sound file the user supplies, that fires the moment Claude Code
needs attention and keeps sounding until the user comes back. Packaged as a Claude Code
plugin distributable from GitHub so others can install it in one command.

## Non-goals

- Cross-platform parity. macOS is the target. The player is dispatched behind one function so
  Linux support can be added later, but no Linux code ships in v0.1.0.
- Desktop notification banners, Slack/push relays, or any remote alerting.
- Per-event distinct sounds. One sound file covers every trigger (explicit user decision).
- Bundling an audio file with the plugin. See "Sound resolution" for why.

## Approach

Claude Code emits a `Notification` hook event whose `matcher` selects on notification type.
The types this plugin cares about already exist and map exactly onto the four moments above:
`permission_prompt`, `idle_prompt`, `agent_needs_input`, `agent_completed`. No polling, no
transcript scraping, no wrapper process — the platform already tells us.

The only genuine design problem is **how a repeating alarm reliably stops.** Three options
were considered:

| Approach | Stop mechanism | Trade-off |
| --- | --- | --- |
| A. Kill-on-next-event | Stop scripts on later hook events kill the looper by PID | Instant, but orphans the loop if no event ever fires (crash, `Ctrl-C`, killed session) |
| B. Self-limiting | Looper plays a bounded number of times, then exits | Cannot orphan, but keeps sounding briefly after the user has already responded |
| **C. A + B (chosen)** | Killed by the next event; hard repeat cap as a backstop | Slightly more moving parts; no runaway failure mode |

**C is chosen.** A alone has an unacceptable failure mode: the user walks away, Claude Code
dies, and the machine plays the alarm on a loop indefinitely. The cap makes that impossible.
B alone is too slow to quiet down. Together they are complementary — the cap is never reached
in the normal path.

## Behaviour

### Triggers

| Notification type | Behaviour | Rationale |
| --- | --- | --- |
| `permission_prompt` | Loop until stopped or capped | The core case. Claude is blocked. |
| `idle_prompt` | Loop until stopped or capped | Claude has been waiting at an empty prompt. |
| `agent_needs_input` | Loop until stopped or capped | A subagent is blocked; same wasted-time cost. |
| `agent_completed` | **Play once** | See below. |

`agent_completed` deliberately does not loop. Since one sound covers every trigger, a looping
"I'm finished" alarm is indistinguishable from a looping "I need you" alarm, and every
completed task would start a five-minute alarm. A single play still gets attention without
turning routine completion into an emergency. *(Proposed as a carve-out during design and
accepted with the rest of the design.)*

### Disarm events

The alarm is cancelled by any of:

| Event | Meaning |
| --- | --- |
| `UserPromptSubmit` | The user typed something — they are back. |
| `PostToolUse` | A tool ran, so a pending permission was approved. |
| `PermissionDenied` | A pending permission was rejected. |
| `SessionEnd` | The session is over. |

`Stop` is deliberately **not** a disarm event: it is what arms the `agent_completed` alert.

### Tunables

All optional environment variables, read at hook time:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CLAUDE_ALERT_SOUND` | unset | Explicit path to the sound file |
| `CLAUDE_ALERT_INTERVAL` | `20` | Seconds between repeats |
| `CLAUDE_ALERT_MAX` | `15` | Maximum repeats (≈5 minutes at the default interval) |
| `CLAUDE_ALERT_DISABLE` | unset | Set to `1` to mute entirely |
| `CLAUDE_ALERT_PLAYER` | auto | Playback command; overridden by tests |
| `CLAUDE_ALERT_HOME` | `~/.claude` | Where `alert-sound.*` is looked up. A test seam, not a user-facing knob — it exists so the suite never touches the real home directory. |

### Sound resolution

First hit wins:

1. `$CLAUDE_ALERT_SOUND`
2. First match of `~/.claude/alert-sound.{wav,mp3,aiff,aif,m4a,caf}` — **the zero-config path;
   the user drops their file here and nothing else is needed**
3. `/System/Library/Sounds/Submarine.aiff` — present on every macOS install
4. Nothing found → exit 0 silently, appending one line to the state-directory log

No audio file ships with the plugin. Falling back to a stock macOS system sound avoids
redistributing third-party audio and its licensing questions, and keeps the repo text-only.

## Architecture

```
claude-alert/                                 ← GitHub repo; also the marketplace
├── .claude-plugin/
│   └── marketplace.json                      ← catalog
├── plugins/
│   └── claude-alert/
│       ├── .claude-plugin/plugin.json
│       ├── hooks/hooks.json
│       ├── commands/alert-test.md            ← /alert-test
│       └── scripts/
│           ├── lib.sh
│           ├── alert-start.sh
│           ├── alert-loop.sh
│           ├── alert-stop.sh
│           └── alert-test.sh
├── tests/
│   ├── run.sh
│   └── helpers/fake-player.sh
├── .github/workflows/ci.yml
├── LICENSE                                   ← MIT
└── README.md
```

### Components

Each script has one job and is testable on its own.

**`lib.sh`** — no side effects, sourced by the others. Provides: extraction of flat top-level
string fields from the JSON on stdin; sound resolution; player dispatch; state-directory
paths. Deliberately dependency-free — it uses `jq` when present and falls back to `grep -oE`,
because macOS ships neither `jq` nor a guaranteed `python3`, and only flat string fields
(`session_id`, `hook_event_name`) are ever needed.

**`alert-start.sh`** — invoked by the `Notification` hook with `--loop` or `--once`.
Reads stdin, extracts `session_id`, honours `CLAUDE_ALERT_DISABLE`, resolves the sound, kills
any looper already running for this session, spawns the new one detached via `nohup`, records
its PID, and **always exits 0 immediately** so Claude Code is never blocked or slowed.

**`alert-loop.sh`** — the detached process. Plays, sleeps `INTERVAL`, repeats up to `MAX`
times. Records its `afplay` child's PID and traps `TERM`/`INT` so that killing the loop also
silences the currently-playing sound rather than leaving it to finish. Removes its own PID
file on exit by any path.

**`alert-stop.sh`** — invoked by the four disarm events. Extracts `session_id`, kills that
session's looper, clears the PID file. Must be *fast*: `PostToolUse` fires on every single
tool call, so the no-alarm-armed path is a single `[ -f ]` test followed by `exit 0`.

**`/alert-test`** — a command that plays the resolved sound once and prints which file was
chosen and why. Turns "is my sound installed correctly?" into a one-second check instead of
having to provoke a real permission prompt.

### State

`${TMPDIR:-/tmp}/claude-alert/<session_id>.pid`

Keyed by `session_id` (present on every hook payload) so that two concurrent Claude Code
windows do not cancel each other's alarms. `TMPDIR` is per-user on macOS, so no cross-user
collisions.

### Data flow

```
Notification(permission_prompt) ──> alert-start.sh --loop
                                      │ kill any existing looper for session
                                      │ nohup alert-loop.sh &  ──> play/sleep/repeat ×15
                                      │ write <session>.pid
                                      └ exit 0 (immediately)

PostToolUse / UserPromptSubmit / PermissionDenied / SessionEnd
                                   ──> alert-stop.sh
                                      │ no pidfile? exit 0
                                      └ kill looper + its player child, rm pidfile
```

## Error handling

The governing rule: **a failure in this plugin must never break, block, or slow a Claude Code
session.** Every script exits 0 unconditionally.

| Failure | Handling |
| --- | --- |
| No sound file resolvable | Exit 0 silently; log one line to the state dir |
| Player binary missing | Exit 0; log |
| Malformed or empty stdin JSON | No `session_id` → exit 0 without arming |
| State directory not writable | Fall back to a single play, no loop |
| Stale PID file (process already dead) | `kill` failure is ignored; file is removed |
| PID reuse after a crash | Bounded blast radius: at worst one wrong `kill`. The repeat cap means an orphan self-terminates within ≈5 minutes regardless |

## Testing

The player is the injected seam. `CLAUDE_ALERT_PLAYER` defaults to the platform player but
tests point it at a fake that appends a timestamped line to a log file. The whole suite
therefore runs silently, fast, and on CI hardware with no audio device.

`tests/run.sh` — plain bash with a small `assert` helper, no test framework, so there is
nothing to install:

1. `--loop` start writes a PID file and invokes the player
2. Stop removes the process and the PID file
3. Two sessions are independent — stopping one leaves the other running
4. The repeat cap is honoured: the looper exits on its own with no stop event
5. A missing sound file exits 0 and never crashes the hook
6. Starting twice leaves exactly one looper alive (no stacked audio)
7. `--once` (`agent_completed`) plays a single time and writes no PID file
8. `CLAUDE_ALERT_DISABLE=1` suppresses everything
9. Malformed stdin JSON exits 0 and arms nothing

Tests 4 and 6 use a short `CLAUDE_ALERT_INTERVAL` and `CLAUDE_ALERT_MAX` so the suite stays
fast.

## Distribution

`.claude-plugin/marketplace.json` at the repo root, with the plugin referenced by a relative
source resolved against the marketplace root:

```json
{
  "name": "neel-tools",
  "owner": { "name": "Neel Madhav", "url": "https://github.com/madhav-dot-md" },
  "plugins": [
    {
      "name": "claude-alert",
      "source": "./plugins/claude-alert",
      "description": "Plays a sound when Claude Code needs your attention",
      "version": "0.1.0",
      "license": "MIT",
      "keywords": ["hooks", "notification", "sound", "productivity"]
    }
  ]
}
```

The marketplace name is separate from the plugin name so further plugins can be published
under the same marketplace later. This matters because the marketplace name is public and is
baked into every user's install — renaming it later breaks them.

### Deployment parameters

| Parameter | Value |
| --- | --- |
| Repository | `https://github.com/madhav-dot-md/claude-alert` |
| Marketplace name | `neel-tools` |
| Plugin name | `claude-alert` |

`neel-tools` is not among the names Anthropic reserves and does not read as an official
Anthropic source, so it loads as a third-party marketplace without issue. `owner.email` is
left unset — it is optional, and `marketplace.json` is a public file.

### Install, for anyone

```
/plugin marketplace add madhav-dot-md/claude-alert
/plugin install claude-alert@neel-tools
```

Then drop a sound at `~/.claude/alert-sound.wav` and run `/alert-test`. Three lines, and that
is the entire README quickstart.

### Updates

Bump `version` in `plugin.json`; users run `/plugin marketplace update` then `/plugin update`.
Claude Code also background-refreshes public marketplaces on its own.

### CI

GitHub Actions on push and pull request:

- `bash tests/run.sh` — the suite above, silent via the fake player
- JSON syntax validation of `marketplace.json`, `plugin.json`, and `hooks.json`
- `shellcheck` on every script

`claude plugin validate` is documented in the README as a local pre-push step rather than run
in CI, so that CI does not depend on installing the Claude Code CLI.

## Known limitations

- **False disarm on subagent alerts.** An `agent_needs_input` alarm may share a `session_id`
  with the parent session; a `PostToolUse` in the parent would then cancel it. The result is a
  missed alarm, never a stuck one — the safe direction to fail.
- **`PostToolUse` fires on every tool call.** That is one short-lived shell spawn per tool.
  The no-alarm path is a single file test, so the cost is negligible, but it is real.
- **macOS only in v0.1.0.** On Linux the plugin resolves no player, logs, and stays silent.
