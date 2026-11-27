# Antigravity sessions and weeks

Status: implemented 2026-11-28 (macOS menu bar, computed by the CLI).

Antigravity › Plan gets the Sessions | Weeks section Claude › Plan has
(`docs/design/claude-session-usage.md`): every 5-hour session of the last seven
days and the last four weeks, each with its spend at API prices, its share of
the 5-hour and weekly limits, the chats and models behind it, and what a full
session or week is worth. The math is Claude's, unchanged; this document only
covers what differs for Antigravity.

## Quota groups

Antigravity meters models in groups ("Gemini Models", "Claude and GPT models").
The models of a group share one 5-hour and one weekly limit, so every group has
its own sessions and weeks. `codeburn limits --provider antigravity` returns one
Claude-shaped report per group:

```
{ "generatedAt": "...", "plan": "Google AI Pro", "readingsThrough": "...",
  "groups": [{ "id": "gemini", "name": "Gemini Models",
               "models": ["Gemini 3.1 Pro (High)", ...],
               "report": <the LimitsOutput `codeburn limits` gives for Claude> }] }
```

- A call belongs to the group whose model list names its family (Gemini,
  Claude, GPT); a group without a model list is matched by its id and name.
  Anything not Gemini falls to the group that is not Gemini's.
- Before any reading, both of today's groups are listed, so spend still shows
  per inferred session.
- The menu bar shows a `Gemini | Claude and GPT` switch above the section when
  more than one group has activity, and opens on the group with the running
  session, else the one used last. With one used group it shows that group's
  name as a caption instead.
- Under each group's 5-hour and weekly bars sits the same spend line Claude's
  bars have ("$4 so far · 1M tokens · +3% of your week").

## Readings

The menu bar logs every Antigravity quota read, local or remote, to
`antigravity-limit-readings.jsonl` in the CodeBurn cache directory, with the
same file rules as `claude-limit-readings.jsonl` (mode 0600, one `O_APPEND`
write per line, lines older than 35 days pruned daily):

```
{"at":"2026-11-27T22:00:04.000Z","ok":true,"plan":"Google AI Pro","source":"remote",
 "groups":[{"id":"gemini","name":"Gemini Models","models":["Gemini 3.1 Pro (High)"],
            "five_hour":{"pct":12,"resetsAt":"2026-11-28T02:02:39.000Z"},
            "seven_day":{"pct":9,"resetsAt":"2026-12-04T15:04:49.000Z"}}]}
{"at":"...","ok":false,"reason":"auth"}
```

- `pct` is percent used, `(1 − remainingFraction) × 100`, to two decimals.
  Google reports whole percents in practice (0.99, 0.85).
- Failures: `auth` (signed out), `network` (local probe or Google failed),
  `no_windows` (a legacy payload without groups). Having no sign-in at all is
  the routine disconnected state and is not logged.
- **Idle buckets.** An unused bucket reads full with a reset that keeps sliding
  to "now + the window", or with no reset. The CLI drops a bucket under 0.5%
  whose reset is within 3 minutes of now + its window, and one without a reset;
  otherwise every idle reading would name a window nobody started.

### Live readings

As for Claude: while the Antigravity app, `agy` or the IDE wrote a
conversation (`.db`, `.db-wal`, `.pb` under `~/.gemini/antigravity*`) in the
last 10 minutes, quota is read every 2 minutes (5 in Low Power Mode), whatever
the usage refresh cadence. FSEvents, no polling. Settings › Antigravity ›
Session numbers turns it off (`codeburn.antigravitySessions.liveWhileActive`,
on by default). Each read refreshes the report.

## Windows start on the first message

Claude windows start on 10-minute marks. Antigravity's start on the first
message of an idle group, to the second, and report their reset 0–2 s after
that message's timestamp. Measured on 2026-11-27:

| Window | Reported reset | First call |
|---|---|---|
| Gemini weekly | 2026-12-04 15:04:49Z | 2026-11-27 15:04:48.972Z |
| Gemini 5-hour | 2026-11-28 02:02:39Z | 2026-11-27 21:02:37.617Z |

So the CLI keys Antigravity windows to the minute (`windowStepMs`, a new
`computeClaudeLimits` input that defaults to Claude's 10 minutes) and moves
every reset one minute earlier. A window then starts 0.5–1.5 minutes before
its first call, never after it; otherwise the call that opened a window would
fall just outside it and show as a one-call inferred session. Inferred windows
start at their first call's minute.

## What is not there

- **Exact limit hits.** Claude Code writes a record for every refused request;
  no Antigravity record of a quota refusal is known, so a 100% comes only from
  a reading and full-session values stay `≈`.
- Paired devices, the All-tab row and the second menu bar line stay
  Claude-only.
- Chats have no folder: "Copy resume command" copies `agy --resume <id>`.

## Code

- CLI: `src/antigravity-limits.ts` (log parsing, idle filter, group mapping,
  the per-group run of `computeClaudeLimits`); `--provider` on `limits` in
  `src/main.ts` and the `serve` allowlist; tests in
  `tests/antigravity-limits.test.ts`.
- Menu bar: `Data/AntigravityLimits.swift` (report decoding, the reading-log
  line, the live-reading preference and activity watch);
  `AppStore.refreshAntigravityLimits`; `runAntigravityLiveReadingIfDue` in
  `CodeBurnApp`; `Views/AntigravitySessionsSection.swift`, which renders the
  Claude views with `\.limitsProvider` set to `.antigravity`; tests in
  `AntigravityLimitsTests.swift`.
