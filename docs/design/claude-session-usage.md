# Claude session and week usage

Status: implemented (V1, 2026-10-14). The Sessions and Weeks lists were
redesigned on 2026-10-17 (week strip, day groups, tabbed rows); this document
describes the redesign. Where the implementation settled a detail the spec left
open, see Implementation notes at the end.

Surface: native macOS menu bar (`mac/`), computed by the CLI (`src/`)

## Product decision

Claude subscriptions meter usage in two windows: a 5-hour window, which
Claude's own usage screen calls the "session", and a weekly window. CodeBurn
already shows both as percentages in the Plan insight. It does not show what a
session or a week cost at API prices, how much of the week one session used, or
when a limit actually ran out.

This feature makes the 5-hour session the unit of the Claude Plan view. For the
current session, every session of the last seven days, and the last four
weeks, the popover shows:

- dollars at API list prices and tokens spent inside the window;
- how much of the 5-hour limit and of the weekly limit the window used;
- what a full session and a full week are worth in API dollars, measured per
  window rather than assumed;
- when a limit ran out, to the minute.

Heavy users are stopped by the weekly limit and pace themselves with 5-hour
sessions, so the headline line connects the two: "A full 5-hour session ≈ 12% of
your week · ≈ 7 left".

Every number is measured, never assumed, because the dollar value of a limit
moves. On the account this was designed against, a full 5-hour session was
worth about $95 in early October and about $190 a week later, and a full week
went from about $890 to about $1,490 within a month. Each value is computed from
its own window's data, and this spec states how each one is measured and how
precise it is.

Figures in the sketches below are illustrative.

## Terms

- **Session**: one Claude 5-hour usage window, from Anthropic's reported reset
  time minus five hours to that reset time. Windows start on 10-minute marks.
- **Week**: one Claude weekly window (all models), from its reported reset time
  minus seven days, or from an early reset.
- **Chat**: one Claude Code conversation (what `codeburn sessions` calls a
  session). Chats are the breakdown inside a session.
- **Reading**: one successful fetch of the Claude usage endpoint, giving the
  percent used and the reset time of each window.
- **Spent**: the API list-price cost of local Claude calls, priced the way
  codeburn already prices them.

## Scope

V1 includes:

- A one-line Claude session summary on the All tab that opens Claude › Plan.
- In Claude › Plan: spend, tokens and week share for the current session; spend
  and full-week value for the current week; the share-of-week rate and sessions
  left; a "week runs out first" line.
- A Sessions | Weeks switch in Claude › Plan: the 5-hour sessions of the last
  seven days, and the last four weeks.
- An expandable session row: spend, tokens, 5-hour and week use, the full
  session value, the ran-out time, and the chats that made up its spend.
- Trend › Hours for Today: spend or tokens per local hour, with each 5-hour
  session shaded.
- A "Claude session" choice for the existing menu bar second line.
- Background limit readings while Claude is active, independent of the usage
  refresh setting, recorded in a reading log.
- Limit-hit times read from refused requests in Claude Code transcripts.
- A read-only CLI command that computes all of the above, served by
  `codeburn serve`.

V1 does not include:

- Codex, Cursor or any other provider. Codex is the first candidate; see
  Backlog.
- The desktop app, the Windows tray or the GNOME extension.
- More than one Claude account (`CLAUDE_CONFIG_DIRS` profiles).
- Model-scoped weekly windows (Opus, Sonnet, Fable) in the session math. They
  keep their existing Plan rows.
- An hour-of-day view for past days. Hours are for Today only.
- Notifications. The "runs out first" state is a line in the Plan view only.
- A Claude Code statusline hook. See Rejected approaches.

## Interaction contract

### All tab

One row under the hero total, shown only when Claude is connected:

```
Claude session  61% · $116 · +8% of week                    ›
```

Clicking it selects the Claude provider tab and the Plan insight. With no
session running it reads `Claude · week 8% · resets Wed 11:00 ›`. The row is
not shown on other provider tabs.

### Claude › Plan

The existing 5-hour and 7-day rows keep their bars and projections. Each gains a
spend line, and a summary line follows them:

```
Current session (5h)                     61% · resets 16:00
[█████████████████████████████░░░░░░░░░░░░░░░░░░░░░]
$116 so far · 375M tokens · +8% of your week · full ≈ $190

Current week                           8% · resets Wed 11:00
[████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░]
$118 so far · full week ≈ $1,470

A full 5-hour session ≈ 12% of your week · ≈ 7 left
```

- The summary line reads "Not enough sessions yet to measure" until five
  sessions qualify (see Derived numbers).
- When the week will run out before the current session does, the summary line
  becomes `Week runs out first, at about 82% of this session`.
- After a limit ran out it becomes `Week ran out at 03:47 · resets Wed 11:00`
  (or `Session ran out at 17:32 · resets 18:00`), using the refused-request
  time.
- With no session running, the session row reads `No session running · the
  next one starts with your next message`.
- Model-scoped weekly rows (Opus, Sonnet, Fable) stay as they are.

### Sessions and Weeks

Under the bars sits a title, `This week · 32% used` or `Last 4 weeks · API
prices`, with a Sessions | Weeks switch beside it, remembered across launches
and defaulting to Sessions. When a limit ran out, or the week will run out
before the current session, a warning callout above the title says so (the
lines in Claude › Plan above); otherwise there is no summary line.

Sessions starts with the **week strip**: the current week's used share split
into one block per session, oldest on the left, each as wide as its share of
the week, the running session in the lighter accent. A striped block after
them is as wide as one full session. Pointing at a block lights up its row and
the other way round; clicking a block opens its row. Under the strip:
`1 block = 1 session` on the left and `full session ≈ 8% · ≈ 8 left` on the
right (or "Not enough sessions yet to measure").

The list holds every 5-hour session of the last seven days, newest first,
grouped under the local day it started (`TODAY · FRI  $32`, `YESTERDAY · THU
$151`, `WED  $228`, each with the day's total), with a divider at each weekly
reset in range:

```
This week · 32% used                         [Sessions|Weeks]
[███|██|█|███|██|█|▌|██░░░░ stripes ░░                       ]
1 block = 1 session               full session ≈ 8% · ≈ 8 left
API PRICES                    SPENT        5-HOUR      WEEK
TODAY · FRI                                             $32
■ 21:10–02:10 · now            $30   ▬▬──────  30%     +3%
■ 16:10–21:10                   $2   ────────   3%     +0%
YESTERDAY · THU                                        $151
■ 20:10–01:10                  $43   ▬▬▬▬────  44%     +3%
── week reset · Wed 11:00 ────────────────────────────────
Show all 23 ›
```

- The square before each row has its strip block's color. The running row has
  an accent background and says `now`. There are no chevrons: the whole row is
  a button and lights up on hover.
- The 5-hour column is a meter and a percent; the meter turns accent at 90%.
- Eight rows are shown, then `Show all N ›` expands the list in place.
- `⚠︎` after the time marks a session in which a limit ran out.
- `–` means no reading exists for that value, `≈` marks an estimate and `≥` a
  lower bound. See Display rules.
- A day's total counts all of the sessions that started on it, also those past
  the fold, so the rows always add up to it when the list is expanded.

A session that ran past midnight stays under the day it started, so the rows
of a day miss what that session spent after midnight, while the headline's
Today counts the calendar day. A line under the next day's header gives that
part, and on today the calendar total that matches the headline:

```
TODAY · SAT                                             $61
◧ +$27 after midnight from Fri 21:10 session      $88 today
■ 12:00–17:00 · now            $24   ▬───────  ≥23%    ≈+2%
■ 02:10–07:10                  $37   ▬▬──────   34%     +3%
YESTERDAY · FRI                                         $40
■ 21:10–02:10 · into Sat       $38   ▬▬──────  ≥38%     +3%
```

- The square is the session's, outlined and filled for the part it spent after
  midnight. Pointing at the line lights up the session's row and block;
  clicking it opens the row. The row says `· into Sat` unless it is running.
- The header keeps the day's own sessions, so its rows still add up to it.
- A day no session started on still gets a header when one carried into it
  (working past midnight without a new session), with a total of `$0`.
- Left out under $0.50, and when the CLI's midnight is not one in the Mac's
  time zone.

Clicking a row opens it in place. The open row drops the old Spent / 5-hour /
Week tiles, which repeated the row, for one line of what the row does not say,
`375M tokens  full session ≈ $190`, and a Chats | Hours | Models switch. The
chosen tab is shared by every open row, so switching to Hours compares
sessions.

- **Chats**: the top three chats and `N more ›`, each with a bar behind it as
  wide as its share of the session's spend. A chat row has two lines: its name,
  then `project · 4 prompts · 23:13–23:53`. Clicking it lists the prompts typed
  in this session (two lines each, the whole text on click or hover, `Show N
  more`) and offers **Copy resume command** (`cd '<folder>' && claude --resume
  <id>`). Subagents fold into their parent.
- A chat is named, in order, by Monocode's name for it, its own title (a
  `/rename`, else Claude's generated one), its first prompt, and its project.
  Claude Code names terminal chats but not the ones Monocode runs through the
  SDK, which is where most of those names were missing.
- **Hours**: one bar per hour of the window with its spend, and a line for the
  5-hour percent at the end of each hour (dashed across hours with no
  reading). A running session shows the hours ahead striped, and a dashed
  `now` marker. Pointing at a bar reads `18:10–19:10 · $9 · 5h 6% → 15%`.
- **Models**: spend and tokens per model, with share bars.
- Warnings sit under the tab as callouts: `Ran out at 17:32 after $101.75`,
  `Week ran out at …`, `Used outside this Mac …`, missing readings and
  unpriced models. A session the week reset inside adds `The week reset at …:
  +2% this week, +3% last week`.

Weeks lists the current week and the three before it, under two lines of
context:

```
Last 4 weeks · API prices                    [Sessions|Weeks]
┌ THIS WEEK VS LAST, SAME POINT (FRI 01:26)          −22% ┐
│ This week  ▬▬▬▬────────────────────────      $409 · 32% │
│ Last week  ▬▬▬▬▬───────────────────────      $525 · 41% │
└─────────────────────────────────────────────────────────┘
avg full week ≈ $1,386               this week on pace for 86%
                        SPENT            USED      FULL WEEK
This week · since Wed    $409  ▮▮▮▮▮▮▮──   32%    ≈ $1,279
Oct 7–14   RAN OUT     $1,492  ▮▮▮▮▮▮▮▮▮  100%      $1,492
```

- The comparison is the previous week as it stood the same time into it as
  now is into this week; the figure on the right is the change in spend. It is
  left out when the previous week was cut short before that point.
- The average is over the listed past weeks with a full-week value; the pace
  is the 7-day bar's own linear projection, left out when it falls back to the
  last cycle.
- Each row's Used column is a small strip of that week's sessions (gray for
  past weeks, deep accent for a week that ran out) and a percent. A week that
  ran out carries a `RAN OUT` chip.

An open week has `900M tokens  8 sessions` and a Days | Sessions | Models
switch:

- **Days**: one bar per 24 hours from the weekly reset, with the week percent
  as a line; days ahead are striped in the running week. Pointing at a bar
  reads `Thu · $151 · week 17% → 29%`.
- **Sessions**: the four sessions that took the most of the week, with a bar
  and their share, `N more`, and for the running week `All in Sessions ›`,
  which switches the list.
- **Models**: as for a session.
- `Ran out Tue 03:47` is a callout. A week cut short by a moved reset says so
  and shows no full-week value; a week with no readings at its start says its
  dates are inferred.

### Trend › Hours

When the period is Today, the Trend insight gains a `Days | Hours` switch next
to the existing `Cost | Tokens` toggle. Hours draws 24 bars for the local day,
reusing `TrendChart` and its hover card. The hover card lists the hour's spend,
tokens and top three chats. On the Claude tab each 5-hour session is shaded
behind the bars and labelled with its 5-hour percent. Other periods keep the
daily chart.

### Menu bar second line

`MenubarSecondRow` gains a `claudeSession` metric: `5h 61% · $116 · wk +8%`.
Like the existing metrics, it hides itself when it has no data (no session
running, or Claude not connected). It refreshes on the reading schedule below,
so it stays current while Claude is working, even in Manual refresh mode.

## Measurement contract

### Inputs

1. **Readings**: each successful fetch of `api/oauth/usage` (already made by
   `ClaudeSubscriptionService`), recorded in the reading log with its time: the
   percent used and reset time of `five_hour`, `seven_day` and any scoped weekly
   windows. Anthropic reports whole percents.
2. **Refused requests**: Claude Code writes a record for every request refused
   at a limit, carrying `quotaLimits.rateLimitType` (`five_hour` or
   `seven_day`) and `quotaLimits.resetsAt`. The first refused request in a
   window is the exact moment that limit reached 100%.
3. **Calls**: every local Claude call, with its own timestamp, model, four
   token counts and list-price cost, as codeburn already parses and prices them
   (streaming duplicates removed, subagents counted once).

### Windows

- A session's identity is its reset time rounded to the nearest 10 minutes.
  Raw reset times jitter by up to a second (07:59:59.6 against 08:00:00.0);
  rounding stops one session splitting into two.
- Session boundaries come from readings or refused requests. When neither
  exists, the session is inferred from calls: it starts at the first call after
  the previous session ended, rounded down to a 10-minute mark, and lasts five
  hours. Inferred sessions show their times with `≈`. Sessions are never assumed
  to start on the hour.
- Weeks come from the `seven_day` reset time in readings. A reading whose weekly
  reset time moved, or whose weekly percent dropped before the reset, ends the
  previous week at that reading (an early reset or a schedule change). Weeks are
  never assumed to last seven days.

### Per-session numbers

- **Spent and tokens**: the sum over calls with a timestamp in [start, end).
  Exact at list prices. Covers this Mac only.
- **5h used**: the highest reading for the session. If the last reading came
  before the session's last call, it is a lower bound (`≥ 57%`). If a
  `five_hour` refused request exists, it is exactly 100% at that time.
- **Week used**: the first `seven_day` reading after the session's last call
  minus the last `seven_day` reading before its first call. If the week reset
  inside the session, the part after the reset counts as this week (from 0) and
  the part before it as last week. Missing readings are handled under Gaps.
- **Full session value**: spent ÷ 5h used × 100. Exact when the session ran
  out, using spend up to the refused request. Otherwise `≈`, and hidden below
  20% used, where whole-percent readings are too coarse.
- **Ran out**: the limit and time of the first refused request in the session.
- **Outside this Mac**: a session whose 5-hour percent rose by at least one
  point while local spend stayed under $0.50 is labelled "used outside this
  Mac". Mixed use is not detected; percents are always account-wide.

### Per-week numbers

- **Spent and tokens**: calls in [week start, week end or now).
- **Used**: the highest `seven_day` reading of the week; exactly 100% at the
  first `seven_day` refused request.
- **Full week value**: spent ÷ used × 100. Exact when the week ran out, using
  spend up to the refused request. Otherwise `≈`, and hidden below 5% used.

### Derived numbers

- **Share of week per full session** (the rate): Σ week used ÷ Σ 5h used over
  the most recent sessions, up to ten, that used at least 30% of their 5-hour
  limit, have both bracketing readings, and fall in the current or previous
  week. Shown once at least five qualify. It restarts when the plan tier
  changes. Older weeks are excluded because Anthropic changes limits without
  notice.
- **Sessions left**: (100 − week used) ÷ rate, rounded down, shown as `≈ 7`.
- **Week runs out first**: with current session use S, week use W and rate r
  (week points per 5-hour point), the week runs out at S + (100 − W) ÷ r percent
  of the session. The line shows when that is below 100.

### Hourly

Today's calls bucketed by local hour, summing the existing 15-minute timeline.
Exact. A daylight-saving change day has 23 or 25 bars.

### Gaps

- No reading after a session's last call: 5h used is a lower bound, and week
  used is estimated as spent × this week's week points per dollar, marked `≈`.
  Without a usable reading this week, the previous week's ratio is used; without
  either, the value is `–`.
- No reading at all for a session: 5h used is `–`, week used is estimated as
  above, and the times are inferred.
- Failed checks are recorded in the reading log with a reason. A session whose
  values are estimated because checks failed says so in its expanded row: "No
  limit readings 00:20–05:20 · Anthropic asked CodeBurn to slow down".

### Display rules

- Percents are whole numbers. Anthropic reports whole percents, so a measured
  per-session week share is accurate to about ±1 point.
- `≈` estimated, `≥` lower bound, `–` unknown, `⚠︎` a limit ran out.
- Money follows the user's currency setting and the existing currency
  formatter. Section captions say "API prices".
- A session or week containing a model codeburn cannot price shows its spend as
  `≥ $X`, with a note naming the model.

## Readings: schedule and storage

### Schedule

- **Claude is active** when any Claude transcript under the configured Claude
  config directories was written in the last 10 minutes. Detection uses
  FSEvents, not polling.
- While active, and for 10 minutes after the last write, the usage endpoint is
  read every 2 minutes (every 5 minutes in Low Power Mode), whatever the usage
  refresh cadence is, Manual included. The 10-minute tail captures the final
  values after the last call.
- While idle, the existing `SubscriptionRefreshCadence` applies unchanged.
- Opening the popover and a window rollover still force a reading, as today.
- A 429 from the usage endpoint keeps the existing back-off and `Retry-After`
  handling, with the persisted block capped at 30 minutes.
- The CLI output for this feature and the second line refresh on the same ticks,
  through `codeburn serve`.
- A Settings toggle turns the active schedule off (see Settings contract).

### Reading log

- File: `claude-limit-readings.jsonl` in the codeburn cache directory
  (`CODEBURN_CACHE_DIR`, else `~/.cache/codeburn`), mode `0600`, append-only,
  one JSON object per line, each line written with a single `O_APPEND` write.
- Every check is recorded, including unchanged and failed ones, so a gap can be
  told apart from "nothing changed":

```
{"at":"2026-10-14T11:26:04Z","ok":true,"plan":"Max 5x",
 "five_hour":{"pct":58,"resetsAt":"2026-10-14T12:59:59.622Z"},
 "seven_day":{"pct":8,"resetsAt":"2026-10-21T07:59:59.622Z"},
 "scoped":[{"label":"Weekly · Fable","pct":0,
            "resetsAt":"2026-10-21T08:00:00Z"}]}
{"at":"2026-10-14T11:28:04Z","ok":false,"reason":"rate_limited",
 "retryAfter":300}
```

- `reason` is one of `rate_limited`, `auth`, `network`, `decode` or
  `no_windows`.
- Lines older than 35 days are pruned once a day by rewriting the file through
  the existing atomic `SafeFile.write`.
- On first run, the rows of `subscription-snapshots.json` are imported as
  readings so existing history is kept. Those rows only record rises, so
  imported history produces more `≥` and `≈` values than new history.

### Fixes to existing code

- `SubscriptionSnapshotStore.record()` keys rows by the exact reset time,
  sub-second jitter included, which splits one window into several keys.
  Normalize the key to the nearest 10 minutes.
- A failed `SubscriptionSnapshotStore.loadAll()` returns an empty list, and the
  next `record()` then overwrites the file. It must leave the file alone and
  retry instead.

## Edge cases

| Case | Behavior |
|---|---|
| Week resets inside a session | The Week column shows this week's part; the expanded row shows both parts. |
| Early reset or moved reset day | Week boundaries follow the readings; the Weeks table shows the real dates. |
| Back-to-back sessions | A reading belongs to the session its `five_hour` reset time names. |
| Limit hit, user keeps trying | The ran-out time is the first refused request; later refusals are ignored. |
| No session running | The session row and the second line show their idle copy. |
| Usage elsewhere (claude.ai, phone, another Mac, cloud tasks) | Percents include it, dollars do not; zero-local-spend sessions are labelled. |
| Plan tier changes | The rate restarts; past sessions keep their measured values. |
| Menu bar not running | No readings; values become `≈` or `–`, never invented. |
| Unpriced model | Spend shows `≥ $X` with a note. |
| Several Claude config directories | V1 uses the default account. |
| Clock or time zone change | Everything is stored in UTC and shown in local time. |

## Visual contract

- No new navigation. Rows expand in place. Sessions | Weeks and the tabs of an
  open row use a gray segmented track with the chosen option raised
  (`ClaudeSegmented`); Trend's Days | Hours keeps the pill style
  (`TrendMetricToggle`).
- Reuse `UtilizationRow` and `UtilizationBar` for the session and week bars,
  `TrendChart` and `BarTooltipCard` for Trend › Hours, and the active accent
  preset. Warnings use the quota banner's palette (`QuotaWarningPalette`).
- Upper-case captions are cased in CodeBurn's display language, not the Mac's
  region, so a Turkish-region Mac does not print "API PRİCES".
- Figures use `Font.codeMono` with monospaced digits, like the rest of the
  popover.
- The popover stays 360 points wide. Every new row must fit in all six locales;
  the longest locale sets the column widths.
- Every new string goes through `L()` and exists in all six
  `Localizable.strings` files, as the existing localization tests enforce.
- Bars and markers carry VoiceOver labels with the same text, for example
  "Week used 12 percent, measured".

## Settings contract

- General › Display › Second row gains "Claude session".
- General › Usage Refresh gains "Keep Claude session numbers live while Claude
  is working", on by default, key `codeburn.claudeSessions.liveWhileActive`,
  with the caption "Checks your Claude limits every 2 minutes while Claude is
  working and for 10 minutes after. Nothing runs while idle."
- Turning it off restores today's behavior: readings then happen only when the
  popover opens or a window resets, and more values become `≈` or `–`.

## Code boundaries

- **mac/ (Swift)**: activity detection (FSEvents); the reading schedule in the
  refresh loop (`CodeBurnApp.runRefreshLoopTick`, `QuotaRefreshDecision`); the
  reading log writer next to `ClaudeSubscriptionService`; decoding the new CLI
  output and `history.timeline` (shipped in every payload today but not
  decoded); and the views: the All-tab row, the Plan additions, Sessions |
  Weeks, Trend › Hours and the second-line metric.
- **src/ (CLI)**: a parser addition that extracts refused-request records
  (`quotaLimits` on rejected assistant messages) as limit events; a module that
  builds sessions and weeks from the reading log, the limit events and the
  calls, and computes every number in the Measurement contract; a read-only
  command, proposed as `codeburn limits --format json`, added to the `serve`
  allowlist; and `sessionId` on the `history.timeline` session series, so the
  Hours hover card can name chats.
- The CLI owns all the math, so the desktop app and the Windows tray can reuse
  it later. The menu bar records readings and renders.
- `codeburn limits` makes no network calls. It reads the reading log the menu
  bar writes; without the log it still reports spend per inferred session and
  limit-hit times.

### Output shape

```
{
  "generatedAt": "...", "plan": "Max 5x", "readingsThrough": "...",
  "current": { "session": Session | null, "week": Week },
  "rate": { "weekPerSessionPoint": 0.12, "basis": 9, "restartedAt": null },
  "sessionsLeft": 7,
  "runsOutFirstAtSessionPct": null,
  "sessions": [Session],
  "weeks": [Week],
  "gaps": [{ "from": "...", "to": "...", "reason": "rate_limited" }]
}

Session: { start, end, startInferred, spentUSD,
           tokens: { input, output, cacheRead, cacheWrite },
           fiveHourPct, fiveHourQuality, weekPct, weekQuality,
           weekSplit?: { thisWeek, lastWeek },
           fullSessionUSD?, fullSessionQuality,
           ranOut?: { limit, at }, outsideThisMac, unpricedModels,
           chats: [{ sessionId, title, spentUSD, project, path,
                      firstAt, lastAt, promptCount,
                      prompts: [{ at, text }] }],
           models: [{ model, spentUSD, tokens }],
           hours: [{ start, end, spentUSD, tokens, fiveHourPct }],
           afterMidnight?: { at, spentUSD } }

Week:    { start, end, endReason, spentUSD, tokens, usedPct, usedQuality,
           fullWeekUSD?, fullWeekQuality, ranOutAt?,
           models: [{ model, spentUSD, tokens }],
           days: [{ start, end, spentUSD, tokens, usedPct }],
           sessions: [{ id, start, end, running, spentUSD,
                        weekPct, weekQuality }],
           previousAtSamePoint?: { at, spentUSD, usedPct, usedQuality } }

Top level also has "fullWeekAverage": { "usd": 1386, "basis": 2 }.
```

- `hours` cut a session into hours from its start and `days` cut a week into
  24-hour slices from its reset, up to now. A slice's percent is the highest
  reading taken by its end, `null` when no reading fell inside it, and 100 from
  the slice in which the limit ran out.
- `afterMidnight` is the local midnight inside a session (in the CLI's time
  zone, which `--timezone` sets), once it has passed, and what the session
  spent from then to its end. A session stays inside one day otherwise; five
  hours never hold two midnights.
- `models` groups calls by display name ("Opus 5.5"), most expensive first.
- A chat's `prompts` are the first 12 typed inside the window, cleaned (see
  Implementation notes) and capped at 400 characters, with secrets masked the
  way `codeburn why` masks them; `promptCount` counts all of them.
- A week's `sessions` are its sessions oldest first, each with its share of
  that week; a session the week reset inside appears in both weeks with its
  part of each.
- `previousAtSamePoint` is on the running week only: the previous week's spend
  up to the same offset from its start, and its highest reading by then
  (`lowerBound` when calls came after that reading).
- The app decodes every one of these as optional, so it keeps working against
  an older CLI and only hides the tabs it has no data for.

Each `*Quality` is `exact` (from a refused request), `measured`, `lowerBound`,
`estimated` or `unknown`. Money is in USD; the app converts it to the display
currency as it does today.

## Reliability

| Number | Source | Accuracy |
|---|---|---|
| Spent, tokens | Calls by timestamp × list prices | Exact at list prices, this Mac only |
| Hourly | Calls by timestamp | Exact |
| 5h used | Highest reading | ±1 point; exactly 100% on a limit hit |
| Week used per session | Bracketing readings | ±1 point |
| Full session or week value | Spent ÷ used | Exact on a limit hit; otherwise `≈`, hidden when too coarse |
| Rate, sessions left | Sums over recent sessions | About ±1 point once five sessions qualify |
| Ran-out time | First refused request | To the second |

Evidence from 30 days of one heavy Max 5x account (Sep 14 to Oct 14, 2026):

- **Prices**: codeburn's live and bundled prices match Anthropic's list for
  Opus 5.5, Opus 5 and Fable 5.1, including 1-hour cache writes (2× input) and
  fast mode. Opus 5.5 has no long-context surcharge, so 1M-context calls are
  priced correctly.
- **Readings**: with Manual refresh, the menu bar only reads limits when the
  popover opens or a window resets. About 30% of that month's Claude spend had
  no limit reading after it in its window, and some days had none. This is why
  the active schedule is part of V1.
- **Precision**: the usage endpoint returns whole percents, and so does Claude
  Code's statusline.
- **Window starts**: every observed reset fell on a 10-minute mark. A
  reconstruction that started windows on the hour produced a false "$293 spent
  without hitting the limit" window that straddled two real sessions.
- **Limit hits**: refused requests gave five exact 5-hour hits in early October,
  at $91 to $102 each (one at $56), and the weekly hit to the second.
- **Drift**: a full session went from about $95 in early October to about $190
  in mid-October, and a full week from about $890 to about $1,490 over the
  month. Cache reads were 96–99% of tokens in both periods, so caching does not
  explain it. Hence per-window values, and a rate drawn from recent weeks only.

## Rejected approaches

- **Claude Code statusline hook.** The statusline input carries the 5-hour and
  weekly percents with the chat id, but it only renders in interactive terminal
  sessions (headless and orchestrated runs never update it), its values come
  from that process's last response and can lag the endpoint, and installing it
  edits the user's Claude Code settings. Its percents are whole numbers too, so
  it adds no precision.
- **Splitting the week by dollar share alone.** It assumes Anthropic weighs
  usage like API prices and that all usage is local. It survives only as the
  fallback estimate when readings are missing.
- **A fixed dollar value per session or week.** It drifted 2× within a week on
  the measured account.

## Verification and acceptance

CLI (vitest, with fixture reading logs and transcripts):

- Windows: reset jitter collapses to one session; 10-minute rounding; inferred
  windows round down and are flagged; nothing is aligned to the hour.
- Week used: bracketing readings; a reset inside a session splits correctly;
  back-to-back sessions assign the boundary reading by its reset time.
- Limit events: the first refused request sets an exact 100% and the ran-out
  time; later refusals are ignored; `five_hour` and `seven_day` are kept apart.
- Gaps: missing readings yield `lowerBound`, `estimated` or `unknown`, never a
  measured value.
- Values: full-session and full-week values are exact on a hit and hidden
  under their thresholds; unpriced models yield `≥`.
- Rate: the ten-session cap, the 30% threshold, the current-and-previous-week
  limit, the five-session minimum and the restart on a plan tier change.
- Closure: across a closed week, the per-session week shares sum to the week's
  final percent within ±2 points.
- Hourly: local-hour buckets, and daylight-saving days with 23 and 25 hours.
- Days: a session across local midnight gets what it spent after it; one
  inside a day, or running before its midnight, gets none.

Menu bar (XCTest):

- Reading schedule: reads every 2 minutes while active and through the
  10-minute tail, every 5 minutes in Low Power Mode, none while idle in Manual
  mode; the toggle restores today's behavior; the 429 block is capped at 30
  minutes.
- Reading log: every check recorded, failures with reasons, atomic appends,
  35-day pruning, and the one-time import of `subscription-snapshots.json`.
- `SubscriptionSnapshotStore`: normalized keys; a failed load never overwrites
  the file.
- Days: a carry-over goes under the next day, also a day with no session of
  its own; one from another time zone or under $0.50 is left out.
- Localization coverage and catalog tests pass for all new strings in all six
  locales, and the new rows fit 360 points in the longest locale.

On a real machine:

- With Manual refresh, an hour of Claude Code use produces readings about every
  2 minutes during it and for 10 minutes after, and none while idle.
- The Plan view, the Sessions list and `codeburn limits --format json` agree.
- A session that hits the 5-hour limit shows `⚠︎` and the exact time.
- A warm `codeburn limits` through `serve` answers in under 100 ms at p95.

## Backlog (not in this implementation)

- Codex: rollouts carry `rate_limits.primary` and `rate_limits.secondary`
  `used_percent` on every `token_count` event, which gives per-session weekly
  shares without polling. The parser ignores them today.
- The desktop app, the Windows tray and GNOME, reusing `codeburn limits`.
- Several Claude accounts, each with its own sessions and weeks.
- Model-scoped weekly windows in the session math.
- An hour-of-day view for past days.
- Opening a chat from a session row in the desktop app.

## Implementation notes

- **Refused requests** are read by an incremental scanner of the default
  account's transcripts (`src/claude-limit-sources.ts`) rather than inside the
  session parser: it decodes only lines that mention `quotaLimits`, resumes
  each append-only file where the last scan stopped
  (`claude-limit-events-cache.json` in the cache directory), and holds a line
  back until its newline lands. A resident `serve` reuses the scan for up to a
  minute.
- **A moved weekly reset** ends the previous week at the new week's nominal
  start (its reset time minus seven days) when that falls after the old week's
  last reading, and at the first new reading otherwise. A week cut short this
  way shows no full-week value, since Anthropic changes limits when it moves
  them.
- **A percent drop of one point** within a week is treated as rounding; an
  early reset needs a drop of at least two points or a drop to zero.
- **Week points per dollar**, the fallback estimate, divides a week's highest
  reading by the spend up to that reading, not by the whole week's spend.
- **`limits` through `serve`** is never replayed from the output memo, because
  the reading log and the clock are outside the watched session roots. Its
  parse range is whole local days so the parse memo is reused; warm answers
  measured about 45 ms against a 30-day history of 47,000 calls.
- **Dates inside localized lines** follow CodeBurn's display language, so an
  English UI on a Turkish-region Mac says "Wed", not "Çar".
- **Chat names from Monocode.** `src/monocode-titles.ts` reads Monocode's
  `sessions` table (`provider_session_id` → `title`, harness `claude`)
  read-only through `src/sqlite.ts`, strips the `claude · ` prefix, skips chats
  it has not named yet, and memoizes on the database's and its log's mtime. A
  missing app or another schema gives no names, never an error.
  `CODEBURN_MONOCODE_DB` points it elsewhere.
- **Prompts are cleaned** of image paths, pasted-content tags, system
  reminders and a hand-off's preamble; a slash command reads `/name args`.
  Text the user did not type (task notifications, command output, caveats,
  another session's message, a skill's body, "Your response above was cut
  off") is dropped.
- **The parser kept the wrong prompt.** Claude Code writes an `isMeta` user
  entry after some prompts, a pasted image's path or a skill's body, and the
  parser started a new turn on it, so the turn's prompt became
  `[Image: source: …]`. An `isMeta` entry that arrives before Claude has
  answered now leaves the prompt alone; turns, calls and costs are unchanged.
  A `/rename` (`custom-title`) now wins over `ai-title`. Both needed the
  `meta-prompts-v1` Claude parse-version bump, a one-time re-read.
- **Past weeks are labelled `Oct 7–14`** (`Sep 30–Oct 7` across months), so
  a `RAN OUT` chip fits beside the label.
- **No shrink-to-fit in list rows.** In the offscreen renders SwiftUI applied
  `minimumScaleFactor` to week rows that had room, so rows truncate instead.
- **The running week's row** shows its start weekday only ("This week · since
  Wed"); the time is in the expanded row, because the full form does not fit
  360 points next to four columns.
