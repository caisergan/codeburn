// Claude 5-hour sessions and weekly windows, priced at API list prices.
//
// Everything here is pure: the readings the menubar logs from Anthropic's
// usage endpoint, the refused requests Claude Code writes to its transcripts,
// and the locally priced calls go in, and every number the Plan view shows
// comes out. Nothing is assumed about a limit's dollar value or about window
// alignment; see docs/design/claude-session-usage.md for the contract.

export const MINUTE_MS = 60 * 1000
export const HOUR_MS = 60 * MINUTE_MS
export const FIVE_HOURS_MS = 5 * HOUR_MS
export const DAY_MS = 24 * HOUR_MS
export const WEEK_MS = 7 * DAY_MS
const TEN_MINUTES_MS = 10 * MINUTE_MS

/// How long the Sessions list looks back.
export const SESSION_LIST_MS = WEEK_MS
/// The Weeks table: the current week and the three before it.
export const WEEK_LIST_COUNT = 4
/// Below these, whole-percent readings are too coarse to divide by.
const MIN_FIVE_HOUR_PCT_FOR_VALUE = 20
const MIN_WEEK_PCT_FOR_VALUE = 5
/// The rate: sessions that used at least this much of their 5-hour limit,
/// at most RATE_MAX_SESSIONS of them, shown once RATE_MIN_SESSIONS qualify.
const RATE_MIN_FIVE_HOUR_PCT = 30
const RATE_MAX_SESSIONS = 10
const RATE_MIN_SESSIONS = 5
/// A session whose 5-hour percent rose while this Mac spent less than this.
const OUTSIDE_THIS_MAC_USD = 0.5
/// The prompts a chat row carries for one session; the rest are only counted.
const MAX_PROMPTS_PER_CHAT = 12

export type LimitName = 'five_hour' | 'seven_day'
export type Quality = 'exact' | 'measured' | 'lowerBound' | 'estimated' | 'unknown'
export type CheckFailureReason = 'rate_limited' | 'auth' | 'network' | 'decode' | 'no_windows'

export type WindowReading = { pct: number; resetsAt: number }

/// One successful check of the usage endpoint. `imported` rows came from the
/// old snapshot store, which only kept rises, so they never prove "unchanged".
export type LimitReading = {
  at: number
  plan?: string
  fiveHour?: WindowReading
  sevenDay?: WindowReading
  imported?: boolean
}

export type FailedCheck = { at: number; reason: string; retryAfter?: number }

/// The first refused request of a window is the moment that limit hit 100%.
export type LimitEvent = { limit: LimitName; at: number; resetsAt: number }

export type TokenCounts = { input: number; output: number; cacheRead: number; cacheWrite: number }

export type LimitCall = {
  at: number
  costUSD: number
  tokens: TokenCounts
  model: string
  /// Display name ("Opus 5"); the raw id when the caller has none.
  modelName?: string
  unpriced: boolean
  chatId: string
  chatTitle: string
  /// The chat's project folder name, and its path for `claude --resume`.
  chatProject?: string
  chatPath?: string
}

/// One prompt the user typed, cleaned of what tools wrapped around it.
export type LimitPrompt = { at: number; chatId: string; text: string }

export type LimitsInput = {
  now: number
  readings: LimitReading[]
  failures: FailedCheck[]
  events: LimitEvent[]
  calls: LimitCall[]
  /// Sorted by time; optional so callers without prompts need not pass any.
  prompts?: LimitPrompt[]
}

export type Gap = { from: string; to: string; reason: string }

export type ChatShare = {
  sessionId: string
  title: string
  spentUSD: number
  project?: string
  path?: string
  /// The chat's first and last call inside the window.
  firstAt: string
  lastAt: string
  /// Prompts typed inside the window: all of them counted, the first
  /// MAX_PROMPTS_PER_CHAT kept.
  promptCount: number
  prompts: Array<{ at: string; text: string }>
}

export type ModelShare = { model: string; spentUSD: number; tokens: number }

/// One hour of a session, from its start. `fiveHourPct` is the highest
/// reading taken by the end of the hour, null when no reading fell inside it.
export type HourOut = { start: string; end: string; spentUSD: number; tokens: number; fiveHourPct: number | null }

/// One 24-hour slice of a week, from the week's reset. `usedPct` follows the
/// same rule as an hour's `fiveHourPct`.
export type DayOut = { start: string; end: string; spentUSD: number; tokens: number; usedPct: number | null }

/// A session as one block of a week: its share of that week.
export type WeekSession = {
  id: string
  start: string
  end: string
  running: boolean
  spentUSD: number
  weekPct: number | null
  weekQuality: Quality
}

export type SessionOut = {
  id: string
  start: string
  end: string
  startInferred: boolean
  running: boolean
  spentUSD: number
  tokens: TokenCounts
  fiveHourPct: number | null
  fiveHourQuality: Quality
  weekPct: number | null
  weekQuality: Quality
  weekSplit?: { thisWeek: number | null; lastWeek: number | null; resetAt: string }
  weekFrom?: number
  weekTo?: number
  fullSessionUSD?: number
  fullSessionQuality: Quality
  ranOut?: { limit: LimitName; at: string; spentUSD: number }
  outsideThisMac: boolean
  unpricedModels: string[]
  chats: ChatShare[]
  models: ModelShare[]
  hours: HourOut[]
  /// The local midnight inside the session, once it has passed, and what the
  /// session spent after it: the menubar lists a session under the day it
  /// started, so this part belongs to the next day's total.
  afterMidnight?: { at: string; spentUSD: number }
  gap?: Gap
}

export type WeekEndReason = 'reset' | 'early_reset' | 'moved' | 'inferred' | 'running'

export type WeekOut = {
  start: string
  end: string
  endReason: WeekEndReason
  startInferred: boolean
  running: boolean
  spentUSD: number
  tokens: TokenCounts
  usedPct: number | null
  usedQuality: Quality
  fullWeekUSD?: number
  fullWeekQuality: Quality
  ranOutAt?: string
  unpricedModels: string[]
  models: ModelShare[]
  days: DayOut[]
  /// The week's sessions, oldest first.
  sessions: WeekSession[]
  /// The running week only: the previous week at the same time into it.
  previousAtSamePoint?: { at: string; spentUSD: number; usedPct: number | null; usedQuality: Quality }
}

export type LimitsOutput = {
  generatedAt: string
  plan: string | null
  readingsThrough: string | null
  current: { session: SessionOut | null; week: WeekOut | null }
  rate: { weekPerSessionPoint: number | null; basis: number; restartedAt: string | null }
  sessionsLeft: number | null
  runsOutFirstAtSessionPct: number | null
  /// The mean full-week value of the listed past weeks that have one.
  fullWeekAverage: { usd: number | null; basis: number }
  sessions: SessionOut[]
  weeks: WeekOut[]
  gaps: Gap[]
}

/// A window's identity. Raw reset times jitter by up to a second
/// (07:59:59.6 against 08:00:00.0), which would split one window in two.
export function windowKey(resetsAt: number): number {
  return Math.round(resetsAt / TEN_MINUTES_MS) * TEN_MINUTES_MS
}

function floorToTenMinutes(ms: number): number {
  return Math.floor(ms / TEN_MINUTES_MS) * TEN_MINUTES_MS
}

const iso = (ms: number): string => new Date(ms).toISOString()

function zeroTokens(): TokenCounts {
  return { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
}

function addTokens(into: TokenCounts, add: TokenCounts): void {
  into.input += add.input
  into.output += add.output
  into.cacheRead += add.cacheRead
  into.cacheWrite += add.cacheWrite
}

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------

type SessionWindow = { key: number; start: number; end: number; inferred: boolean }

/// Every 5-hour window the data proves or implies, oldest first. Readings and
/// refused requests name windows by their reset time; calls outside every named
/// window open an inferred one at the 10-minute mark at or before them.
function isSortedByTime(calls: LimitCall[]): boolean {
  for (let i = 1; i < calls.length; i++) if (calls[i]!.at < calls[i - 1]!.at) return false
  return true
}

export function buildSessionWindows(readings: LimitReading[], events: LimitEvent[], calls: LimitCall[]): SessionWindow[] {
  const keys = new Set<number>()
  for (const r of readings) if (r.fiveHour) keys.add(windowKey(r.fiveHour.resetsAt))
  for (const e of events) if (e.limit === 'five_hour') keys.add(windowKey(e.resetsAt))

  const known: SessionWindow[] = [...keys].sort((a, b) => a - b)
    .map(key => ({ key, start: key - FIVE_HOURS_MS, end: key, inferred: false }))
  // An early reset opens the next window before the previous one would have
  // ended; the previous one ends where the next begins.
  for (let i = 0; i + 1 < known.length; i++) {
    if (known[i]!.end > known[i + 1]!.start) known[i]!.end = known[i + 1]!.start
  }

  const windows: SessionWindow[] = []
  let k = 0
  let prevEnd = Number.NEGATIVE_INFINITY
  const sortedCalls = isSortedByTime(calls) ? calls : [...calls].sort((a, b) => a.at - b.at)
  for (const call of sortedCalls) {
    while (k < known.length && known[k]!.end <= call.at) {
      windows.push(known[k]!)
      prevEnd = Math.max(prevEnd, known[k]!.end)
      k++
    }
    const last = windows[windows.length - 1]
    if (k < known.length && known[k]!.start <= call.at) continue
    if (last && last.inferred && call.at < last.end) continue
    const start = Math.max(prevEnd, floorToTenMinutes(call.at))
    let end = start + FIVE_HOURS_MS
    if (k < known.length && known[k]!.start < end) end = known[k]!.start
    windows.push({ key: end, start, end, inferred: true })
    prevEnd = end
  }
  while (k < known.length) windows.push(known[k++]!)
  return windows
}

type WeekWindow = {
  key: number
  start: number
  end: number
  endReason: WeekEndReason
  startInferred: boolean
}

/// Weekly windows from the `seven_day` reset times in readings, oldest first.
/// A reading whose reset time moved, or whose percent dropped before the reset,
/// ends the previous week at that reading. Weeks before the first reading are
/// stepped back seven days at a time and flagged as inferred.
export function buildWeekWindows(readings: LimitReading[], events: LimitEvent[], now: number, count = WEEK_LIST_COUNT): WeekWindow[] {
  type Obs = { at: number; key: number; pct: number | null }
  const obs: Obs[] = []
  for (const r of readings) if (r.sevenDay) obs.push({ at: r.at, key: windowKey(r.sevenDay.resetsAt), pct: r.sevenDay.pct })
  for (const e of events) if (e.limit === 'seven_day') obs.push({ at: e.at, key: windowKey(e.resetsAt), pct: null })
  obs.sort((a, b) => a.at - b.at)

  const weeks: WeekWindow[] = []
  let lastPct: number | null = null
  let lastAt = Number.NEGATIVE_INFINITY
  for (const o of obs) {
    const current = weeks[weeks.length - 1]
    if (!current) {
      weeks.push({ key: o.key, start: o.key - WEEK_MS, end: o.key, endReason: 'reset', startInferred: false })
      lastPct = o.pct
      lastAt = o.at
      continue
    }
    if (o.key === current.key) {
      // Same reset time, but usage fell: an early reset that kept the schedule.
      // A one-point wobble is rounding, not a reset.
      if (o.pct !== null && lastPct !== null && o.at < current.end && (lastPct - o.pct >= 2 || (o.pct === 0 && lastPct > 0))) {
        current.end = o.at
        current.endReason = 'early_reset'
        weeks.push({ key: o.key, start: o.at, end: o.key, endReason: 'reset', startInferred: false })
      }
      if (o.pct !== null) lastPct = o.pct
      lastAt = o.at
      continue
    }
    if (o.key < current.key) continue // a stale reading for an older window
    if (o.at < current.end) {
      // The schedule moved while the week was still running. The new week
      // began at its own nominal start when that falls after the old week's
      // last reading; otherwise all that is known is this reading.
      const nominal = o.key - WEEK_MS
      const cut = nominal > lastAt && nominal <= o.at && nominal > current.start ? nominal : o.at
      current.end = cut
      current.endReason = 'moved'
      weeks.push({ key: o.key, start: cut, end: o.key, endReason: 'reset', startInferred: false })
    } else {
      // A gap of whole weeks with no readings: step back seven days at a time.
      let start = o.key - WEEK_MS
      const filler: WeekWindow[] = []
      while (start - current.end >= WEEK_MS) {
        filler.unshift({ key: start, start: start - WEEK_MS, end: start, endReason: 'inferred', startInferred: true })
        start -= WEEK_MS
      }
      if (start > current.end) {
        // A part-week between the previous reset and this week's start: the
        // schedule moved while nothing was reading it.
        filler.unshift({ key: start, start: current.end, end: start, endReason: 'moved', startInferred: true })
      } else if (start < current.end) {
        start = current.end
      }
      weeks.push(...filler)
      weeks.push({ key: o.key, start: Math.max(o.key - WEEK_MS, current.end), end: o.key, endReason: 'reset', startInferred: false })
    }
    lastPct = o.pct
    lastAt = o.at
  }

  if (weeks.length === 0) return []
  // Weeks the readings never saw end: keep stepping forward until now.
  let last = weeks[weeks.length - 1]!
  while (last.end <= now) {
    const next: WeekWindow = { key: last.end + WEEK_MS, start: last.end, end: last.end + WEEK_MS, endReason: 'reset', startInferred: true }
    weeks.push(next)
    last = next
  }
  // And back before the first reading, so the table has its four weeks.
  while (weeks.length < count + 1 && weeks[0]!.start > now - (count + 1) * WEEK_MS) {
    const first = weeks[0]!
    weeks.unshift({ key: first.start, start: first.start - WEEK_MS, end: first.start, endReason: 'inferred', startInferred: true })
  }
  return weeks
}

function weekAt(weeks: WeekWindow[], ms: number): WeekWindow | undefined {
  return weeks.find(w => w.start <= ms && ms < w.end)
}

// ---------------------------------------------------------------------------
// Spend
// ---------------------------------------------------------------------------

type Spend = { spentUSD: number; tokens: TokenCounts; unpriced: Set<string>; first: number | null; last: number | null }

/// Index of the first call at or after `at`. `calls` is sorted by time.
function lowerBound(calls: LimitCall[], at: number): number {
  let lo = 0
  let hi = calls.length
  while (lo < hi) {
    const mid = (lo + hi) >>> 1
    if (calls[mid]!.at < at) lo = mid + 1
    else hi = mid
  }
  return lo
}

function spendIn(calls: LimitCall[], from: number, to: number): Spend {
  const out: Spend = { spentUSD: 0, tokens: zeroTokens(), unpriced: new Set(), first: null, last: null }
  for (let i = lowerBound(calls, from); i < calls.length; i++) {
    const call = calls[i]!
    if (call.at >= to) break
    out.spentUSD += call.costUSD
    addTokens(out.tokens, call.tokens)
    if (call.unpriced) out.unpriced.add(call.model)
    if (out.first === null || call.at < out.first) out.first = call.at
    if (out.last === null || call.at > out.last) out.last = call.at
  }
  return out
}

function chatsIn(calls: LimitCall[], prompts: LimitPrompt[], from: number, to: number): ChatShare[] {
  type Row = { share: ChatShare; first: number; last: number }
  const byChat = new Map<string, Row>()
  for (let i = lowerBound(calls, from); i < calls.length; i++) {
    const call = calls[i]!
    if (call.at >= to) break
    let row = byChat.get(call.chatId)
    if (!row) {
      row = {
        share: {
          sessionId: call.chatId,
          title: call.chatTitle,
          spentUSD: 0,
          ...(call.chatProject ? { project: call.chatProject } : {}),
          ...(call.chatPath ? { path: call.chatPath } : {}),
          firstAt: '',
          lastAt: '',
          promptCount: 0,
          prompts: [],
        },
        first: call.at,
        last: call.at,
      }
      byChat.set(call.chatId, row)
    }
    row.share.spentUSD += call.costUSD
    row.first = Math.min(row.first, call.at)
    row.last = Math.max(row.last, call.at)
  }
  // A prompt counts for a chat that spent in this window; one typed in a
  // chat that did not is waiting on an answer that lands elsewhere.
  for (let i = lowerBoundPrompts(prompts, from); i < prompts.length; i++) {
    const prompt = prompts[i]!
    if (prompt.at >= to) break
    const row = byChat.get(prompt.chatId)
    if (!row) continue
    row.share.promptCount++
    if (row.share.prompts.length < MAX_PROMPTS_PER_CHAT) row.share.prompts.push({ at: iso(prompt.at), text: prompt.text })
  }
  return [...byChat.values()]
    .map(row => ({ ...row.share, firstAt: iso(row.first), lastAt: iso(row.last) }))
    .sort((a, b) => b.spentUSD - a.spentUSD || a.sessionId.localeCompare(b.sessionId))
}

function lowerBoundPrompts(prompts: LimitPrompt[], at: number): number {
  let lo = 0
  let hi = prompts.length
  while (lo < hi) {
    const mid = (lo + hi) >>> 1
    if (prompts[mid]!.at < at) lo = mid + 1
    else hi = mid
  }
  return lo
}

function modelsIn(calls: LimitCall[], from: number, to: number): ModelShare[] {
  const byModel = new Map<string, ModelShare>()
  for (let i = lowerBound(calls, from); i < calls.length; i++) {
    const call = calls[i]!
    if (call.at >= to) break
    const name = call.modelName ?? call.model
    const row = byModel.get(name) ?? { model: name, spentUSD: 0, tokens: 0 }
    row.spentUSD += call.costUSD
    row.tokens += totalTokens(call.tokens)
    byModel.set(name, row)
  }
  return [...byModel.values()].sort((a, b) => b.spentUSD - a.spentUSD || b.tokens - a.tokens || a.model.localeCompare(b.model))
}

function totalTokens(t: TokenCounts): number {
  return t.input + t.output + t.cacheRead + t.cacheWrite
}

type Slice = { start: number; end: number; spentUSD: number; tokens: number; pct: number | null }

/// `from`..`to` cut into `size` slices, up to `now`, each with its spend and
/// the highest of `readings` (time, percent) taken by its end. A slice with no
/// reading inside it has no percent; from `fullAt` on, the limit is at 100%.
function slices(
  calls: LimitCall[],
  readings: Array<{ at: number; pct: number }>,
  from: number,
  to: number,
  size: number,
  now: number,
  fullAt: number | null,
): Slice[] {
  const out: Slice[] = []
  let highest: number | null = null
  let r = 0
  for (let start = from; start < to && start <= now; start += size) {
    const end = Math.min(start + size, to)
    const spend = spendIn(calls, start, end)
    let inside = false
    while (r < readings.length && readings[r]!.at < end) {
      if (readings[r]!.at >= start) inside = true
      highest = Math.max(highest ?? 0, readings[r]!.pct)
      r++
    }
    let pct = inside ? highest : null
    if (fullAt !== null && fullAt < end) pct = 100
    out.push({ start, end, spentUSD: spend.spentUSD, tokens: totalTokens(spend.tokens), pct })
  }
  return out
}

// ---------------------------------------------------------------------------
// The computation
// ---------------------------------------------------------------------------

type SevenDayObs = { at: number; pct: number; key: number }

type SessionCalc = {
  out: SessionOut
  window: SessionWindow
  plan: string | undefined
  /// Whether this session's week share came from two bracketing readings.
  weekBracketed: boolean
  firstCallAt: number | null
}

export function computeClaudeLimits(input: LimitsInput): LimitsOutput {
  const now = input.now
  const readings = [...input.readings].sort((a, b) => a.at - b.at)
  const calls = [...input.calls].sort((a, b) => a.at - b.at)
  const prompts = [...(input.prompts ?? [])].sort((a, b) => a.at - b.at)
  const events = firstEventPerWindow(input.events)

  const sessionWindows = buildSessionWindows(readings, events, calls)
  const weeks = buildWeekWindows(readings, events, now)

  const sevenDay: SevenDayObs[] = readings
    .filter(r => r.sevenDay)
    .map(r => ({ at: r.at, pct: r.sevenDay!.pct, key: windowKey(r.sevenDay!.resetsAt) }))
  const callTimes = calls.map(c => c.at)
  const gaps = buildGaps(input.failures, readings)
  const readingsByFiveHourKey = new Map<number, LimitReading[]>()
  for (const r of readings) {
    if (!r.fiveHour) continue
    const key = windowKey(r.fiveHour.resetsAt)
    const list = readingsByFiveHourKey.get(key) ?? []
    list.push(r)
    readingsByFiveHourKey.set(key, list)
  }

  // Weeks first: the per-session estimates fall back to the week's ratio.
  const weekOuts = weeks.map(w => computeWeek(w, readings, events, calls, now))
  // Week points per dollar, from the week's highest reading and the spend up
  // to that reading (spend after the last reading has not shown up in it yet).
  const weekRatios = weeks.map((w, i) => {
    const out = weekOuts[i]!
    if (out.usedPct === null || out.usedPct < 1) return null
    const cutoff = out.ranOutAt
      ? Date.parse(out.ranOutAt) + 1
      : Math.max(...readings.filter(r => r.sevenDay && windowKey(r.sevenDay.resetsAt) === w.key && r.at >= w.start && r.at < w.end).map(r => r.at)) + 1
    const spent = spendIn(calls, w.start, Math.min(cutoff, w.end)).spentUSD
    return spent > 0 ? out.usedPct / spent : null
  })
  const ratioForWeek = (w: WeekWindow | undefined): number | null => {
    if (!w) return null
    const i = weeks.indexOf(w)
    return weekRatios[i] ?? weekRatios[i - 1] ?? null
  }

  const calcs: SessionCalc[] = []
  for (let i = 0; i < sessionWindows.length; i++) {
    const window = sessionWindows[i]!
    const spend = spendIn(calls, window.start, window.end)
    const running = window.start <= now && now < window.end
    // A window named only by a reading but never used locally and not running
    // is noise for this view (an idle reading names a window nobody used).
    const sessionReadings = window.inferred ? [] : readingsByFiveHourKey.get(window.key) ?? []
    if (spend.first === null && !running && sessionReadings.every(r => (r.fiveHour?.pct ?? 0) < 1)) continue

    const ranOutEvent = window.inferred ? undefined : events.find(e => e.limit === 'five_hour' && windowKey(e.resetsAt) === window.key)
    const weekRanOut = events.find(e => e.limit === 'seven_day' && e.at >= window.start && e.at < window.end)

    // 5-hour use.
    let fiveHourPct: number | null = null
    let fiveHourQuality: Quality = 'unknown'
    if (ranOutEvent) {
      fiveHourPct = 100
      fiveHourQuality = 'exact'
    } else if (sessionReadings.length > 0) {
      fiveHourPct = Math.max(...sessionReadings.map(r => r.fiveHour!.pct))
      const lastReadingAt = sessionReadings[sessionReadings.length - 1]!.at
      fiveHourQuality = spend.last === null || lastReadingAt >= spend.last ? 'measured' : 'lowerBound'
    }

    // Week use.
    const week = weekAt(weeks, spend.first ?? window.start)
    const nextCallAfter = spend.last === null ? null : nextAfter(callTimes, window.end - 1)
    const prevCallBefore = spend.first === null ? null : prevBefore(callTimes, window.start)
    let weekPct: number | null = null
    let weekQuality: Quality = 'unknown'
    let weekSplit: SessionOut['weekSplit']
    let weekFrom: number | undefined
    let weekTo: number | undefined
    let weekBracketed = false
    if (spend.first !== null && spend.last !== null) {
      const before = lastReadingAtOrBefore(sevenDay, spend.first)
      const after = firstReadingAtOrAfter(sevenDay, spend.last)
      const beforeOk = before && (prevCallBefore === null || before.at >= prevCallBefore)
      const afterOk = after && (nextCallAfter === null || after.at <= nextCallAfter)
      if (beforeOk && afterOk) {
        if (before.key === after.key) {
          weekPct = Math.max(0, after.pct - before.pct)
          weekQuality = 'measured'
          weekFrom = before.pct
          weekTo = after.pct
          weekBracketed = true
        } else {
          // The week reset inside the session. After the reset the week
          // starts from 0; before it, the old week's last reading closes it.
          const resetAt = weekBoundaryBetween(weeks, before.at, after.at)
          const thisWeek = after.pct
          const oldLast = lastReadingAtOrBefore(sevenDay.filter(o => o.key === before.key), resetAt ?? after.at)
          const callsBeforeReset = resetAt === null ? null : prevBefore(callTimes, resetAt)
          const lastWeek = oldLast && (callsBeforeReset === null || oldLast.at >= callsBeforeReset)
            ? Math.max(0, oldLast.pct - before.pct)
            : null
          weekPct = thisWeek
          weekQuality = 'measured'
          weekFrom = 0
          weekTo = after.pct
          weekSplit = { thisWeek, lastWeek, resetAt: iso(resetAt ?? after.at) }
        }
      } else {
        const ratio = ratioForWeek(week)
        if (ratio !== null) {
          weekPct = spend.spentUSD * ratio
          weekQuality = 'estimated'
        }
      }
    }

    // Full session value.
    let fullSessionUSD: number | undefined
    let fullSessionQuality: Quality = 'unknown'
    let ranOut: SessionOut['ranOut']
    if (ranOutEvent) {
      const toHit = spendIn(calls, window.start, ranOutEvent.at + 1).spentUSD
      ranOut = { limit: 'five_hour', at: iso(ranOutEvent.at), spentUSD: toHit }
      fullSessionUSD = toHit
      fullSessionQuality = 'exact'
    } else {
      if (weekRanOut) ranOut = { limit: 'seven_day', at: iso(weekRanOut.at), spentUSD: spendIn(calls, window.start, weekRanOut.at + 1).spentUSD }
      if (fiveHourPct !== null && fiveHourPct >= MIN_FIVE_HOUR_PCT_FOR_VALUE && spend.spentUSD > 0) {
        fullSessionUSD = spend.spentUSD / fiveHourPct * 100
        fullSessionQuality = 'estimated'
      }
    }

    const outsideThisMac = fiveHourPct !== null && fiveHourPct >= 1 && spend.spentUSD < OUTSIDE_THIS_MAC_USD
    const hours = slices(
      calls,
      sessionReadings.map(r => ({ at: r.at, pct: r.fiveHour!.pct })),
      window.start,
      window.end,
      HOUR_MS,
      now,
      ranOutEvent?.at ?? null,
    ).map(h => ({ start: iso(h.start), end: iso(h.end), spentUSD: h.spentUSD, tokens: h.tokens, fiveHourPct: h.pct }))
    const midnight = nextLocalMidnight(window.start)
    const afterMidnight = midnight < window.end && midnight <= now
      ? { at: iso(midnight), spentUSD: spendIn(calls, midnight, window.end).spentUSD }
      : undefined

    const out: SessionOut = {
      id: iso(window.key),
      start: iso(window.start),
      end: iso(window.end),
      startInferred: window.inferred,
      running,
      spentUSD: spend.spentUSD,
      tokens: spend.tokens,
      fiveHourPct,
      fiveHourQuality,
      weekPct: weekPct === null ? null : round1(weekPct),
      weekQuality,
      ...(weekSplit ? { weekSplit } : {}),
      ...(weekFrom !== undefined ? { weekFrom, weekTo } : {}),
      ...(fullSessionUSD !== undefined ? { fullSessionUSD } : {}),
      fullSessionQuality,
      ...(ranOut ? { ranOut } : {}),
      outsideThisMac,
      unpricedModels: [...spend.unpriced].sort(),
      chats: chatsIn(calls, prompts, window.start, window.end),
      models: modelsIn(calls, window.start, window.end),
      hours,
      ...(afterMidnight ? { afterMidnight } : {}),
    }
    const gap = gapFor(gaps, window, sessionReadings.length > 0, fiveHourQuality, weekQuality)
    if (gap) out.gap = gap
    const plan = planAt(readings, window.end)
    calcs.push({ out, window, plan, weekBracketed, firstCallAt: spend.first })
  }

  // The rate: week points per 5-hour point over recent, well-measured
  // sessions in the current or previous week, restarting on a plan change.
  const currentWeekIndex = weeks.findIndex(w => w.start <= now && now < w.end)
  const eligibleWeeks = new Set(currentWeekIndex >= 0 ? [currentWeekIndex, currentWeekIndex - 1] : [])
  const currentPlan = readings.length > 0 ? readings[readings.length - 1]!.plan : undefined
  const restartedAt = planRestart(readings)
  const qualifying = calcs
    .filter(c => !c.out.running)
    .filter(c => c.weekBracketed)
    .filter(c => c.out.fiveHourPct !== null && c.out.fiveHourPct >= RATE_MIN_FIVE_HOUR_PCT)
    .filter(c => c.out.fiveHourQuality === 'measured' || c.out.fiveHourQuality === 'exact')
    .filter(c => {
      const w = weekAt(weeks, c.window.start)
      return w !== undefined && eligibleWeeks.has(weeks.indexOf(w))
    })
    .filter(c => restartedAt === null || (c.firstCallAt ?? c.window.start) >= restartedAt)
    .filter(c => currentPlan === undefined || c.plan === undefined || c.plan === currentPlan)
    .sort((a, b) => b.window.end - a.window.end)
    .slice(0, RATE_MAX_SESSIONS)
  const basis = qualifying.length
  const sumWeek = qualifying.reduce((s, c) => s + (c.out.weekPct ?? 0), 0)
  const sumFive = qualifying.reduce((s, c) => s + (c.out.fiveHourPct ?? 0), 0)
  const rate = basis >= RATE_MIN_SESSIONS && sumFive > 0 && sumWeek > 0 ? sumWeek / sumFive : null

  const currentSession = calcs.find(c => c.out.running)?.out ?? null
  const currentWeek = currentWeekIndex >= 0 ? weekOuts[currentWeekIndex]! : null
  const weekUsed = currentWeek?.usedPct ?? null

  let sessionsLeft: number | null = null
  if (rate !== null && weekUsed !== null) sessionsLeft = Math.max(0, Math.floor((100 - weekUsed) / (100 * rate)))

  let runsOutFirstAtSessionPct: number | null = null
  if (rate !== null && weekUsed !== null && currentSession && currentSession.fiveHourPct !== null) {
    const at = currentSession.fiveHourPct + (100 - weekUsed) / rate
    if (at < 100) runsOutFirstAtSessionPct = Math.max(currentSession.fiveHourPct, Math.round(at))
  }

  // Each week's sessions, as blocks of that week. A session the week reset
  // inside belongs to both weeks, with its part of each.
  weeks.forEach((w, i) => {
    weekOuts[i]!.sessions = calcs.flatMap((c): WeekSession[] => {
      if (c.window.end <= w.start || c.window.start >= w.end) return []
      const split = c.out.weekSplit
      let pct: number | null
      if (split) {
        pct = w.start >= Date.parse(split.resetAt) ? split.thisWeek : split.lastWeek
      } else {
        if (weekAt(weeks, c.firstCallAt ?? c.window.start) !== w) return []
        pct = c.out.weekPct
      }
      return [{
        id: c.out.id,
        start: c.out.start,
        end: c.out.end,
        running: c.out.running,
        spentUSD: c.out.spentUSD,
        weekPct: pct,
        weekQuality: pct === null ? 'unknown' : c.out.weekQuality,
      }]
    })
  })
  if (currentWeekIndex > 0) {
    const same = previousAtSamePoint(weeks[currentWeekIndex]!, weeks[currentWeekIndex - 1]!, readings, events, calls, callTimes, now)
    if (same) weekOuts[currentWeekIndex]!.previousAtSamePoint = same
  }

  const listFrom = now - SESSION_LIST_MS
  const sessions = calcs
    .filter(c => c.out.running || (c.window.end > listFrom && c.window.start <= now))
    .map(c => c.out)
    .reverse()

  const weekList: WeekOut[] = []
  for (let i = currentWeekIndex >= 0 ? currentWeekIndex : weeks.length - 1; i >= 0 && weekList.length < WEEK_LIST_COUNT; i--) {
    const w = weeks[i]!
    if (w.start > now) continue
    weekList.push(weekOuts[i]!)
  }

  const fullWeeks = weekList.filter(w => !w.running && w.fullWeekUSD !== undefined)
  const fullWeekAverage = {
    usd: fullWeeks.length > 0 ? fullWeeks.reduce((s, w) => s + w.fullWeekUSD!, 0) / fullWeeks.length : null,
    basis: fullWeeks.length,
  }

  const lastReading = readings.filter(r => !r.imported).at(-1) ?? readings.at(-1)
  return {
    generatedAt: iso(now),
    plan: currentPlan ?? null,
    readingsThrough: lastReading ? iso(lastReading.at) : null,
    current: { session: currentSession, week: currentWeek },
    rate: {
      weekPerSessionPoint: rate === null ? null : Math.round(rate * 10000) / 10000,
      basis,
      restartedAt: restartedAt === null ? null : iso(restartedAt),
    },
    sessionsLeft,
    runsOutFirstAtSessionPct,
    fullWeekAverage,
    sessions,
    weeks: weekList,
    gaps: gaps.filter(g => Date.parse(g.to) >= now - (WEEK_LIST_COUNT + 1) * WEEK_MS),
  }
}

function computeWeek(w: WeekWindow, readings: LimitReading[], events: LimitEvent[], calls: LimitCall[], now: number): WeekOut {
  const running = w.start <= now && now < w.end
  const to = Math.min(w.end, now)
  const spend = spendIn(calls, w.start, to)
  const ranOut = events.find(e => e.limit === 'seven_day' && e.at >= w.start && e.at < w.end)
  const inWeek = readings.filter(r => r.sevenDay && windowKey(r.sevenDay.resetsAt) === w.key && r.at >= w.start && r.at < w.end)

  let usedPct: number | null = null
  let usedQuality: Quality = 'unknown'
  let fullWeekUSD: number | undefined
  let fullWeekQuality: Quality = 'unknown'
  if (ranOut) {
    usedPct = 100
    usedQuality = 'exact'
    fullWeekUSD = spendIn(calls, w.start, ranOut.at + 1).spentUSD
    fullWeekQuality = 'exact'
  } else if (inWeek.length > 0) {
    usedPct = Math.max(...inWeek.map(r => r.sevenDay!.pct))
    const last = inWeek[inWeek.length - 1]!
    usedQuality = spend.last === null || last.at >= spend.last ? 'measured' : 'lowerBound'
    // A week cut short by a moved schedule or an early reset is not a full
    // week's worth of limit: Anthropic changes limits when it moves them.
    const cutShort = w.endReason === 'moved' || w.endReason === 'early_reset'
    if (usedPct >= MIN_WEEK_PCT_FOR_VALUE && spend.spentUSD > 0 && !cutShort) {
      fullWeekUSD = spend.spentUSD / usedPct * 100
      fullWeekQuality = 'estimated'
    }
  }
  const days = slices(
    calls,
    inWeek.map(r => ({ at: r.at, pct: r.sevenDay!.pct })),
    w.start,
    w.end,
    DAY_MS,
    now,
    ranOut?.at ?? null,
  ).map(d => ({ start: iso(d.start), end: iso(d.end), spentUSD: d.spentUSD, tokens: d.tokens, usedPct: d.pct }))
  return {
    start: iso(w.start),
    end: iso(w.end),
    endReason: running ? 'running' : w.endReason,
    startInferred: w.startInferred,
    running,
    spentUSD: spend.spentUSD,
    tokens: spend.tokens,
    usedPct,
    usedQuality,
    ...(fullWeekUSD !== undefined ? { fullWeekUSD } : {}),
    fullWeekQuality,
    ...(ranOut ? { ranOutAt: iso(ranOut.at) } : {}),
    unpricedModels: [...spend.unpriced].sort(),
    models: modelsIn(calls, w.start, to),
    days,
    sessions: [],
  }
}

/// The previous week as it stood the same time into it as `now` is into the
/// current one. Skipped when the previous week was cut short before that point.
function previousAtSamePoint(
  current: WeekWindow,
  previous: WeekWindow,
  readings: LimitReading[],
  events: LimitEvent[],
  calls: LimitCall[],
  callTimes: number[],
  now: number,
): WeekOut['previousAtSamePoint'] {
  const at = previous.start + (now - current.start)
  if (at >= previous.end) return undefined
  const spentUSD = spendIn(calls, previous.start, at + 1).spentUSD
  const ranOut = events.find(e => e.limit === 'seven_day' && e.at >= previous.start && e.at <= at)
  if (ranOut) return { at: iso(at), spentUSD, usedPct: 100, usedQuality: 'exact' }
  const inWeek = readings.filter(r => r.sevenDay && windowKey(r.sevenDay.resetsAt) === previous.key && r.at >= previous.start && r.at <= at)
  if (inWeek.length === 0) return { at: iso(at), spentUSD, usedPct: null, usedQuality: 'unknown' }
  const last = inWeek[inWeek.length - 1]!
  const lastCall = prevBefore(callTimes, at + 1)
  return {
    at: iso(at),
    spentUSD,
    usedPct: Math.max(...inWeek.map(r => r.sevenDay!.pct)),
    usedQuality: lastCall === null || lastCall < previous.start || last.at >= lastCall ? 'measured' : 'lowerBound',
  }
}

/// Later refusals in the same window are retries against a limit already hit.
export function firstEventPerWindow(events: LimitEvent[]): LimitEvent[] {
  const first = new Map<string, LimitEvent>()
  for (const e of events) {
    const key = `${e.limit}|${windowKey(e.resetsAt)}`
    const existing = first.get(key)
    if (!existing || e.at < existing.at) first.set(key, e)
  }
  return [...first.values()].sort((a, b) => a.at - b.at)
}

/// Consecutive failed checks with no success between them, as one range.
export function buildGaps(failures: FailedCheck[], readings: LimitReading[]): Gap[] {
  const successes = readings.filter(r => !r.imported).map(r => r.at).sort((a, b) => a - b)
  const sorted = [...failures].sort((a, b) => a.at - b.at)
  const gaps: Array<{ from: number; to: number; reasons: Map<string, number> }> = []
  for (const f of sorted) {
    const current = gaps[gaps.length - 1]
    const successBetween = current ? successes.some(s => s > current.to && s < f.at) : true
    if (!current || successBetween) {
      gaps.push({ from: f.at, to: f.at, reasons: new Map([[f.reason, 1]]) })
    } else {
      current.to = f.at
      current.reasons.set(f.reason, (current.reasons.get(f.reason) ?? 0) + 1)
    }
  }
  return gaps.map(g => ({
    from: iso(g.from),
    to: iso(g.to),
    reason: [...g.reasons.entries()].sort((a, b) => b[1] - a[1])[0]![0],
  }))
}

function gapFor(gaps: Gap[], window: SessionWindow, hasReadings: boolean, fiveHourQuality: Quality, weekQuality: Quality): Gap | undefined {
  if (hasReadings && fiveHourQuality === 'measured' && weekQuality === 'measured') return undefined
  return gaps.find(g => Date.parse(g.from) < window.end && Date.parse(g.to) >= window.start)
}

function planAt(readings: LimitReading[], at: number): string | undefined {
  let plan: string | undefined
  for (const r of readings) {
    if (r.at > at) break
    if (r.plan) plan = r.plan
  }
  return plan
}

/// The time of the most recent plan tier change, or null if none is recorded.
function planRestart(readings: LimitReading[]): number | null {
  let previous: string | undefined
  let restartedAt: number | null = null
  for (const r of readings) {
    if (!r.plan) continue
    if (previous !== undefined && r.plan !== previous) restartedAt = r.at
    previous = r.plan
  }
  return restartedAt
}

function lastReadingAtOrBefore(obs: SevenDayObs[], at: number): SevenDayObs | undefined {
  let found: SevenDayObs | undefined
  for (const o of obs) {
    if (o.at > at) break
    found = o
  }
  return found
}

function firstReadingAtOrAfter(obs: SevenDayObs[], at: number): SevenDayObs | undefined {
  return obs.find(o => o.at >= at)
}

/// First index whose value is greater than `at` (`strict`) or at least `at`.
function searchTimes(sorted: number[], at: number, strict: boolean): number {
  let lo = 0
  let hi = sorted.length
  while (lo < hi) {
    const mid = (lo + hi) >>> 1
    if (strict ? sorted[mid]! <= at : sorted[mid]! < at) lo = mid + 1
    else hi = mid
  }
  return lo
}

function nextAfter(sorted: number[], at: number): number | null {
  return sorted[searchTimes(sorted, at, true)] ?? null
}

function prevBefore(sorted: number[], at: number): number | null {
  const i = searchTimes(sorted, at, false)
  return i > 0 ? sorted[i - 1]! : null
}

function weekBoundaryBetween(weeks: WeekWindow[], from: number, to: number): number | null {
  for (const w of weeks) if (w.end > from && w.end <= to) return w.end
  return null
}

/// The first local midnight after `ms`, in the process's time zone (which
/// `--timezone` sets).
function nextLocalMidnight(ms: number): number {
  const d = new Date(ms)
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1).getTime()
}

function round1(n: number): number {
  return Math.round(n * 10) / 10
}
