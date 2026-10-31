# Claude window warmer

Status: implemented (V1, 2026-10-31). Where the build settled a detail the
spec left open, see Implementation notes at the end.

Surface: native macOS menu bar (`mac/`), with the scheduler and the warm itself
in the CLI (`src/`), normally running on a paired always-on device.

## Product decision

A Claude 5-hour window starts with the first message after the previous window
ends, and nothing runs in between. If the first real message of the day comes
at 10:30, the window runs until 15:30. A user who runs out at 13:00 then waits
2.5 hours.

Starting the window earlier on purpose moves its reset earlier. One tiny
message at 07:00 starts a 07:00–12:00 window. Real work from 10:30 uses the
rest of that window, and a fresh window is available at 12:00 instead of 15:30.

The warmer sends that tiny message at times the user chooses, and the Plan
header gets a Warm button that sends it on demand. It only acts when no 5-hour
window is running, because a message during an active window changes nothing.

It is for Claude only.

## Terms

- **Window**: one Claude 5-hour usage window, as in
  [claude-session-usage.md](claude-session-usage.md). Windows start on
  10-minute marks, so a warm at 07:04 starts a window at 07:00 that resets at 12:00.
- **Warm**: one minimal Claude Code message whose only purpose is to start a
  window.
- **Warm time**: a local time of day at which the user wants a window to start.
- **Runner**: the device that sends scheduled and on-demand warms, either this
  Mac or a paired device.
- **Idle**: Anthropic's usage endpoint reports the 5-hour window at 0% with no
  reset time (`isIdleFiveHour` in the Plan view).

## Staying within Anthropic's terms

Claude Code's [legal and compliance page](https://code.claude.com/docs/en/legal-and-compliance)
says, among other things:

- "Advertised usage limits for Pro, Max, and Ultra plans assume ordinary,
  individual usage of Claude Code and the Agent SDK."
- OAuth (subscription) authentication "is designed to support ordinary use of
  Claude Code and other native Anthropic applications".
- "developers may not collect, store, or intermediate Claude.ai credentials or
  session tokens", and the rules do not prevent "an end user from signing in to
  the unmodified Claude Code binary with their own Claude subscription".

The warmer is built so that it does nothing beyond what the user could do by
typing one short message into Claude Code themselves:

1. **The unmodified `claude` binary sends every warm**, signed in on the runner
   with the user's own subscription. CodeBurn never sends a message using a
   Claude OAuth token, never calls `api.anthropic.com` for chat, never sets
   Claude Code headers or user agents, and never forwards credentials between
   devices. Pairing carries only the schedule and a "warm now" request.
2. **One real, short message per warm**, no tools, no retries in a loop.
3. **Low volume by design**: at most one scheduled warm per warm time, up to 4
   warm times a day (a day only holds 4.8 windows), and only when idle. A
   scheduled warm that finds a window running does nothing.
4. **The user's own account, for the user**: no warming for other people and no
   shared or pooled accounts. The runner must already be signed in to the same
   Claude account the Mac reads usage for.
5. **Off by default**: the schedule is opt-in, and a paired device only accepts
   warm requests if it was started with `--allow-warm`.

The idle check reuses the usage reading the Plan view already makes. That
endpoint is read-only and is not involved in sending the message.

This is a reading of the published terms, not legal advice. If Anthropic
publishes guidance against warming, the feature should be removed rather than
worked around.

## The warm message

On the runner, in an empty temporary directory:

```
claude -p "Reply with OK." \
  --model haiku \
  --tools "" \
  --setting-sources "" \
  --strict-mcp-config \
  --disable-slash-commands \
  --no-session-persistence
```

- `haiku` with no tools, settings, MCP servers or skills keeps the message as
  small as Claude Code allows (well under one cent at API prices).
- `--no-session-persistence` keeps it out of the transcripts, so it does not
  appear as a chat in CodeBurn's Claude sessions.
- Time limit 90 s. On failure (not signed in, network, rate-limited) the warm is
  recorded as failed with Claude Code's message. Warms are not retried
  automatically, except one retry 2 minutes later for a network error.
- After a successful warm the runner re-reads usage. Success is "a 5-hour reset
  time is now present", and the result is stored as `started 07:00, resets 12:00`.

To check during implementation: a Haiku message must start the shared 5-hour
window. Test it once on an idle window before relying on it.

## Where it runs

The runner is normally the paired Linux VM, which is always on and signed in to
the same Claude account. The Mac may be asleep at 07:00, and the VM is not.

**This Mac** is also offered as a runner, for users without a paired device. It
only fires while the Mac is awake. A warm missed while asleep runs on wake if
the warm time was less than 30 minutes ago, and is skipped otherwise.

### Paired device (the VM)

The VM already runs `codeburn share --always` (today in tmux), which serves the
Mac over mutual TLS with a per-peer token. The warmer adds to that process:

- `codeburn share --always --allow-warm` turns warming on. Without the flag the
  new routes answer 403, so pairing alone never lets a peer spend the device's
  Claude usage.
- **Scheduler**: a timer in the share process. It checks once a minute against
  the stored schedule, evaluated in the schedule's time zone (the VM runs in
  UTC, the user in +03).
- **Stored schedule**: written to the VM's CodeBurn config directory, so a
  restart keeps it. A history of the last 20 warms is stored next to it.

New authenticated routes, using the same token and certificate check as
`/api/claude-limits`:

| Route | Purpose |
|---|---|
| `GET /api/claude-warm` | Schedule, next warm, idle state, last 20 results. Also tells the Mac the device supports warming. |
| `PUT /api/claude-warm/schedule` | Replace the schedule (`enabled`, `times`, `days`, `timeZone`). |
| `POST /api/claude-warm/now` | Warm now if idle. Answers `started`, `skipped (window running, resets 12:00)` or `failed (…)`. |

Old builds answer 404, which the Mac reads as "this device can't warm".

The Mac is the single source of truth for the schedule. It pushes the schedule
to the runner whenever it changes, and again whenever the runner reports a
different one (for example after reinstalling the VM).

Recommended on the VM: move `share --always` from tmux to a systemd user unit
with lingering, so a reboot does not stop the warmer. That is a setup step, not
part of this feature.

### CLI

`codeburn warm` handles manual use and testing:

- `codeburn warm`: warm this machine now if idle (`--force` skips the idle check
  but still sends only one message).
- `codeburn warm --device <name>`: ask a paired device to warm now.
- `codeburn warm --status [--device <name>]`: schedule, next warm and recent
  results as JSON (`--format json`) or text.

## Menu bar

### Plan header: Warm button

The button goes in the Plan header row, between the plan name and the reset
text:

```
Max 5x                        [🔥 Warm]   Resets in 4h 20m     window running: button disabled
Max 5x                        [🔥 Warm]   Next warm 07:00      idle: button enabled
Max 5x                     [◌ Warming…]                        after a click
Max 5x                        [🔥 Warm]   Resets in 5h 0m      started
```

- **Enabled only when idle.** When a window is running it is disabled, with the
  tooltip "A 5-hour window is already running. Resets at 12:00".
- If usage has not loaded yet, or the reading failed, the button is disabled
  with the tooltip "Waiting for Claude usage".
- A click sends the warm through the selected runner, shows "Warming…", then
  refreshes usage, so the existing "Resets in" text appears on its own.
- On failure the header shows a one-line error under the row for 10 seconds,
  for example "Couldn't warm on instance-2026…: Claude Code isn't signed in",
  with a "Warm on this Mac" action when the runner was a paired device.
- When idle and a schedule is on, the reset text is replaced by "Next warm 07:00".
- If no runner is available (no Claude Code on this Mac and no paired device
  that can warm), the button is hidden.

### Settings › Claude › Window Warmer

A new section in the existing Claude settings tab:

```
Window Warmer
  Warm on schedule                                   [  ON ]
  Run on                  [ instance-20260829-212457 (paired) ▾ ]
                          ● Ready · signed in · last warm 07:00 started

  Start a window at
    [ 07:00 ]  → resets 12:00                                  ⊖
    [ 12:00 ]  → resets 17:00                                  ⊖
    [ 17:00 ]  → resets 22:00                                  ⊖
    ⊕ Add time  (adds 22:00)

  Days                    (M)(T)(W)(T)(F)( S)( S)    Every day ▾

  ┌ 0 ─────── 6 ─────── 12 ─────── 18 ──────── 24 ┐
  │        ███████████ ███████████ ███████████     │   preview of the day
  └────────────────────────────────────────────────┘
  Sends one short Claude Code message at each time, only when no
  5-hour window is running. Uses your own Claude Code login on the
  runner; off by default.
```

- **Times** use the standard hour-and-minute picker, shown in the Mac's 24-hour
  or 12-hour setting. Times snap to 10-minute marks, matching how windows start.
- **⊕ Add time** adds a row 5 hours after the last time, since that is when the
  previous window would end. With no rows it adds 07:00. The section allows at
  most 4 rows.
- **The preview bar** shades each scheduled window across the day, so overlaps
  are visible at a glance. A time that falls inside the previous scheduled
  window is shown with an orange note "inside the 07:00 window; it only fires
  if that window wasn't started". It is allowed, not blocked.
- **Days**: a preset menu (Every day, Weekdays, Weekends) plus the day chips for
  a custom set.
- **Run on** lists This Mac (if `claude` is on PATH) and each paired device that
  answers `GET /api/claude-warm`. A device without `--allow-warm` is listed
  greyed out with "Start `codeburn share` with `--allow-warm` to enable".
- **The status line** under Run on shows the runner's readiness (reachable,
  Claude Code signed in) and its last result. Clicking it opens the last 20
  results.
- Changes save immediately and are pushed to the runner. A push failure shows
  "Not synced to <device>, will retry" and retries on each usage refresh.

## Edge cases

- **Window already running at a warm time**: skip and record "skipped, window
  running". This is the normal case on busy days.
- **Usage reading fails at a warm time**: do not send, record "skipped, couldn't
  read usage". Never warm blind on a schedule.
- **Runner unreachable** (Mac side): the button shows the error described above;
  scheduled warms on the VM do not depend on the Mac being online.
- **Weekly limit used up**: skip with "weekly limit reached", because a warm
  can't start a usable window then. The usage reading reports this.
- **DST and travel**: the schedule carries the Mac's IANA time zone. When the Mac's
  time zone changes, the Mac pushes the new zone and times keep their local
  meaning.
- **Two runners**: only the selected runner holds an enabled schedule.
  Selecting a different runner disables the schedule on the old one.
- **Peak hours** (weekdays 15:00–21:00 local) drain the 5-hour meter faster.
  Optional later: a hint in the preview when a window starts during peak hours.
  Not in V1.

## Out of scope

- Warming any provider other than Claude.
- Sending more than the one minimal message, or any "keep-alive" traffic inside a
  window.
- Picking warm times automatically from usage history. Possible later, since
  CodeBurn knows when windows usually start, but V1 uses the user's times.
- Installing the systemd unit on the VM.

## Open questions

1. The user mentioned an existing warmer on the server. It was not found on the
   VM on 2026-10-31. If it exists elsewhere, check its message and timing
   against this spec, and turn it off once this is running so the two don't both
   warm.

## Implementation notes

- **Code**: `src/claude-warm.ts` (schedule, idle check, the `claude -p` send,
  history, scheduler), `src/claude-warm-cli.ts` (`codeburn warm`),
  `src/sharing/claude-warm-peers.ts` (host side), the three routes in
  `src/sharing/share-server.ts`; on the Mac `Data/WindowWarmer.swift` and
  `Views/ClaudeWarmViews.swift`.
- **CLI**: `codeburn warm` (warm now), `codeburn warm status [--devices]`,
  `codeburn warm schedule --set '<json>'`, each with `--device <name|id>` and
  `--format json`. Days on the wire are 0 = Monday … 6 = Sunday.
- **Prompt on stdin**: the message goes to `claude -p` on stdin, so the
  variadic `--tools ""` can never swallow it. `ANTHROPIC_API_KEY`,
  `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_BASE_URL` are removed from the child's
  environment so Claude Code uses the subscription login, the only one with a
  5-hour window.
- **Usage reading retries**: a failed reading is retried twice, 5 s apart,
  before a warm is skipped as `usage_unavailable` (a one-off "fetch failed"
  was seen on the VM).
- **This Mac as runner**: the app checks idle with its own Plan reading and
  then runs `codeburn warm --force`, so the CLI does not read the keychain a
  second time. Scheduled warms on this Mac run from a 60 s timer and on wake.
- **Result reasons** are codes (`window_running`, `weekly_full`,
  `usage_unavailable`, `claude_not_found`, `send_failed`, `no_window_yet`),
  localized by the app.
- **Scheduler**: checks every 30 s, fires a slot within 10 minutes of its time
  and marks it fired before sending, so a restart never sends twice.
- **VM setup (2026-10-31)**: the share runs in the tmux session `codeburn`,
  inside a shell, as `~/.npm-global/bin/codeburn share --always --allow-warm`.
