// Claude window warmer: start a Claude 5-hour window at chosen times by
// sending one minimal message through the user's own signed-in Claude Code
// (`claude -p`). CodeBurn never sends a message with a Claude token itself; the
// usage reading below is the same read-only one the Plan view makes. See
// docs/design/claude-window-warmer.md.

import { spawn } from 'child_process'
import { access, constants, mkdir, mkdtemp, readFile, rm } from 'fs/promises'
import { homedir, tmpdir } from 'os'
import { delimiter, dirname, join } from 'path'

import { writeFileAtomic } from './claude-limit-sources.js'
import { createWarmLogger, warmLogPathFor, type WarmLogger, type WarmLogLevel } from './claude-warm-log.js'
import { getConfigFilePath } from './config.js'
import { fetchClaudeQuota, type ClaudeResult } from './quota/claude.js'

/// 2: auto-warm after reset (`schedule.auto`, `currentWindow`).
export const WARM_STATUS_VERSION = 2
/// A day holds 4.8 five-hour windows, so more times than this can only overlap.
export const MAX_WARM_TIMES = 4
const WINDOW_MS = 5 * 60 * 60 * 1000
const HISTORY_LIMIT = 20
const FIRED_SLOTS_LIMIT = 20
const SEND_TIMEOUT_MS = 90_000
const NETWORK_RETRY_MS = 2 * 60_000
/// How late a scheduled warm may still fire, e.g. after the scheduler's process
/// was busy or restarted. Times are on 10-minute marks, so this never reaches
/// the next one.
const SCHEDULE_GRACE_MINUTES = 10
/// After a warm, how often and how many times usage is re-read for the new
/// window's reset time.
const CONFIRM_READS = 3
const CONFIRM_INTERVAL_MS = 4000
/// Extra attempts at a failed usage reading before a warm is skipped.
const READ_RETRIES = 2
const READ_RETRY_MS = 5000

/// Auto-warm: the hours a reset may fall in (local, from inclusive, to
/// exclusive), so the chain stops overnight. Fixed in V1.
export const AUTO_FROM = '07:00'
export const AUTO_TO = '24:00'
/// The window that just ended must have read above this (2%) to be continued,
/// so a window only a warm started is never extended.
export const AUTO_MIN_PERCENT = 0.02
/// Warms (scheduled + auto) that may start a window per local day.
export const AUTO_DAILY_CAP = 5
/// An auto-warm fires this long after the reset, so the endpoint has moved on.
const AUTO_DELAY_MS = 60_000
/// A reset found later than this (the runner was down) is skipped, not warmed late.
const AUTO_LATE_MS = 10 * 60_000
/// How often usage is read while auto-warm is on, to learn the reset times of
/// windows started by real use.
const AUTO_POLL_MS = 15 * 60_000

/// The message. Short, real, and answerable without tools.
export const WARM_PROMPT = 'Reply with OK.'
/// The prompt goes on stdin. Everything optional is switched off so the
/// message is as small as Claude Code allows, and nothing is written to the
/// transcripts (so it does not show up as a chat).
export const WARM_ARGS = [
  '-p',
  '--model', 'haiku',
  '--tools', '',
  '--setting-sources', '',
  '--strict-mcp-config',
  '--disable-slash-commands',
  '--no-session-persistence',
]

export type AutoWarm = {
  enabled: boolean
  /// "HH:MM"; `to` may be "24:00".
  from: string
  to: string
}

/// 0 = Monday … 6 = Sunday.
export type WarmSchedule = {
  /// The times below; auto-warm has its own switch.
  enabled: boolean
  /// Local "HH:MM" times on 10-minute marks, sorted, at most MAX_WARM_TIMES.
  times: string[]
  days: number[]
  /// IANA zone the times are in (the Mac's), so a runner in UTC fires at the
  /// user's local time.
  timeZone: string
  /// Warm again right after each reset. Absent from version-1 senders.
  auto: AutoWarm
}

export type WarmTrigger = 'manual' | 'scheduled' | 'auto'
export type WarmOutcome = 'started' | 'skipped' | 'failed'
/// Machine-readable why, localized by the app.
export type WarmReason =
  | 'window_running'
  | 'weekly_full'
  | 'usage_unavailable'
  /// Claude Code on the runner has no usable login (never signed in, signed
  /// out, or its login expired and could not be renewed).
  | 'signed_out'
  | 'claude_not_found'
  | 'send_failed'
  | 'no_window_yet'

export type WarmResult = {
  at: string
  trigger: WarmTrigger
  outcome: WarmOutcome
  reason: WarmReason | null
  /// Claude Code's own message on a failed send.
  detail: string | null
  /// The new (started) or running (skipped) window's reset time.
  resetsAt: string | null
  /// "YYYY-MM-DD HH:MM" in the schedule's zone for scheduled warms,
  /// "auto:<reset ISO time>" for auto-warms.
  slot: string | null
}

/// The 5-hour window the runner last saw running, and its highest reading
/// (a fraction), for auto-warm's "only after a window you used" rule.
export type TrackedWindow = {
  resetsAt: string
  maxPercent: number
}

export type WarmState = {
  schedule: WarmSchedule | null
  history: WarmResult[]
  /// Scheduled slots ("YYYY-MM-DD HH:MM") and auto resets ("auto:<iso>")
  /// already fired.
  firedSlots: string[]
  currentWindow: TrackedWindow | null
}

export type FiveHourReading =
  | { state: 'idle' }
  | { state: 'running'; resetsAt: string | null; percent: number }
  | { state: 'weekly_full'; resetsAt: string | null }
  | { state: 'unknown'; problem?: UsageProblem; detail?: string | null }

/// Why usage could not be read. `signed_out` and `login_expired` need the user
/// to sign in to Claude Code on that machine again; the rest are the endpoint's.
export type UsageProblem =
  | 'signed_out'
  | 'login_expired'
  | 'access_denied'
  | 'rate_limited'
  | 'rejected'
  | 'unreachable'
  | 'no_five_hour'
  | 'error'

export type SendResult = { ok: true } | { ok: false; reason: 'claude_not_found' | 'send_failed'; detail: string | null; network: boolean }

// ---------------------------------------------------------------- schedule

const TIME_RE = /^(\d{1,2}):(\d{2})$/

export function isValidTimeZone(zone: string): boolean {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: zone })
    return true
  } catch {
    return false
  }
}

function minutesOf(time: string): number | null {
  const m = TIME_RE.exec(time)
  if (!m) return null
  const h = Number(m[1])
  const min = Number(m[2])
  if (h > 23 || min > 59) return null
  return h * 60 + min
}

/// Like minutesOf, but also accepts "24:00" (the end of the day).
function boundaryMinutesOf(time: string): number | null {
  return time === '24:00' ? 24 * 60 : minutesOf(time)
}

function hhmm(minutes: number): string {
  return `${String(Math.floor(minutes / 60)).padStart(2, '0')}:${String(minutes % 60).padStart(2, '0')}`
}

/// Validates and normalizes a schedule from the wire or a file: times snapped
/// to 10-minute marks, de-duplicated and sorted; days de-duplicated. Returns
/// null when it is not a schedule at all.
export function parseSchedule(input: unknown): WarmSchedule | null {
  if (!input || typeof input !== 'object') return null
  const raw = input as Record<string, unknown>
  if (typeof raw.enabled !== 'boolean' || !Array.isArray(raw.times) || !Array.isArray(raw.days)) return null
  if (typeof raw.timeZone !== 'string' || !isValidTimeZone(raw.timeZone)) return null
  const minutes = new Set<number>()
  for (const t of raw.times) {
    if (typeof t !== 'string') return null
    const m = minutesOf(t)
    if (m === null) return null
    // Windows start on 10-minute marks; 23:55 snaps down rather than wrapping.
    minutes.add(Math.min(Math.round(m / 10) * 10, 23 * 60 + 50))
  }
  if (minutes.size > MAX_WARM_TIMES) return null
  const days = new Set<number>()
  for (const d of raw.days) {
    if (typeof d !== 'number' || !Number.isInteger(d) || d < 0 || d > 6) return null
    days.add(d)
  }
  const auto = parseAuto(raw.auto)
  if (!auto) return null
  return {
    enabled: raw.enabled,
    times: [...minutes].sort((a, b) => a - b).map(hhmm),
    days: [...days].sort((a, b) => a - b),
    timeZone: raw.timeZone,
    auto,
  }
}

/// Missing (a version-1 sender or file) means off with the default hours.
function parseAuto(input: unknown): AutoWarm | null {
  if (input === undefined || input === null) return { enabled: false, from: AUTO_FROM, to: AUTO_TO }
  if (typeof input !== 'object') return null
  const raw = input as Record<string, unknown>
  if (typeof raw.enabled !== 'boolean') return null
  const from = typeof raw.from === 'string' ? raw.from : AUTO_FROM
  const to = typeof raw.to === 'string' ? raw.to : AUTO_TO
  const a = minutesOf(from)
  const b = boundaryMinutesOf(to)
  if (a === null || b === null || a >= b) return null
  return { enabled: raw.enabled, from: hhmm(a), to: b === 24 * 60 ? '24:00' : hhmm(b) }
}

const WEEKDAYS: Record<string, number> = { Mon: 0, Tue: 1, Wed: 2, Thu: 3, Fri: 4, Sat: 5, Sun: 6 }

/// Wall-clock date, weekday and minute of `now` in `timeZone`.
export function localParts(now: Date, timeZone: string): { ymd: string; weekday: number; minutes: number } {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
    weekday: 'short',
  }).formatToParts(now)
  const get = (type: string): string => parts.find(p => p.type === type)?.value ?? ''
  return {
    ymd: `${get('year')}-${get('month')}-${get('day')}`,
    weekday: WEEKDAYS[get('weekday')] ?? 0,
    minutes: Number(get('hour')) * 60 + Number(get('minute')),
  }
}

/// The scheduled warm that is due at `now`, if any: a time on an enabled day
/// that passed less than the grace period ago.
export function dueSlot(schedule: WarmSchedule, now: Date): { slot: string; time: string } | null {
  if (!schedule.enabled) return null
  const local = localParts(now, schedule.timeZone)
  if (!schedule.days.includes(local.weekday)) return null
  for (const time of schedule.times) {
    const m = minutesOf(time)
    if (m === null) continue
    if (local.minutes >= m && local.minutes < m + SCHEDULE_GRACE_MINUTES) {
      return { slot: `${local.ymd} ${time}`, time }
    }
  }
  return null
}

// ---------------------------------------------------------------- auto-warm

/// Reset times from the endpoint are compared to the minute, so a few
/// seconds' jitter between readings is still the same window.
function windowKey(resetsAt: string): string | null {
  const ms = Date.parse(resetsAt)
  if (!Number.isFinite(ms)) return null
  return new Date(Math.round(ms / 60_000) * 60_000).toISOString()
}

/// Folds a reading into the tracked window: the same window keeps its highest
/// reading, a new one starts over. Other readings change nothing, so the ended
/// window is still known when its reset comes.
export function trackWindow(current: TrackedWindow | null, reading: FiveHourReading): TrackedWindow | null {
  if (reading.state !== 'running' || !reading.resetsAt) return current
  const key = windowKey(reading.resetsAt)
  if (!key) return current
  if (current && current.resetsAt === key) {
    return reading.percent > current.maxPercent ? { resetsAt: key, maxPercent: reading.percent } : current
  }
  return { resetsAt: key, maxPercent: reading.percent }
}

/// Warms that started a window on the schedule or automatically, on the local
/// day of `now`. Manual warms do not count toward the cap.
export function automaticStartsOn(history: WarmResult[], now: Date, timeZone: string): number {
  const today = localParts(now, timeZone).ymd
  return history.filter(r =>
    r.trigger !== 'manual'
    && r.outcome === 'started'
    && localParts(new Date(r.at), timeZone).ymd === today,
  ).length
}

/// The auto-warm due at `now`, if any: the tracked window has reset at least a
/// minute ago (and at most ten), the reset fell inside the active hours, the
/// window was really used, the reset has not fired yet, and the daily cap is
/// not reached. The idle check happens in the warm itself.
export function dueAutoWarm(state: WarmState, now: Date): { key: string; resetsAt: string } | null {
  const { schedule, currentWindow: window } = state
  if (!schedule?.auto.enabled || !window) return null
  const resetMs = Date.parse(window.resetsAt)
  const since = now.getTime() - resetMs
  if (!Number.isFinite(resetMs) || since < AUTO_DELAY_MS || since > AUTO_LATE_MS) return null
  const key = `auto:${window.resetsAt}`
  if (state.firedSlots.includes(key)) return null
  if (!inActiveHours(schedule, new Date(resetMs))) return null
  if (window.maxPercent <= AUTO_MIN_PERCENT) return null
  if (automaticStartsOn(state.history, now, schedule.timeZone) >= AUTO_DAILY_CAP) return null
  return { key, resetsAt: window.resetsAt }
}

export function inActiveHours(schedule: WarmSchedule, at: Date): boolean {
  const from = minutesOf(schedule.auto.from) ?? 0
  const to = boundaryMinutesOf(schedule.auto.to) ?? 24 * 60
  const m = localParts(at, schedule.timeZone).minutes
  return m >= from && m < to
}

// ---------------------------------------------------------------- state

export function warmStatePath(): string {
  return join(dirname(getConfigFilePath()), 'claude-warm.json')
}

export async function loadWarmState(path: string = warmStatePath()): Promise<WarmState> {
  try {
    const raw = JSON.parse(await readFile(path, 'utf-8')) as Partial<WarmState>
    return {
      schedule: parseSchedule(raw.schedule),
      history: Array.isArray(raw.history) ? raw.history.slice(0, HISTORY_LIMIT) : [],
      firedSlots: Array.isArray(raw.firedSlots) ? raw.firedSlots.filter((s): s is string => typeof s === 'string') : [],
      currentWindow: parseTrackedWindow(raw.currentWindow),
    }
  } catch {
    return { schedule: null, history: [], firedSlots: [], currentWindow: null }
  }
}

function parseTrackedWindow(input: unknown): TrackedWindow | null {
  if (!input || typeof input !== 'object') return null
  const raw = input as Record<string, unknown>
  if (typeof raw.resetsAt !== 'string' || typeof raw.maxPercent !== 'number') return null
  const key = windowKey(raw.resetsAt)
  return key ? { resetsAt: key, maxPercent: raw.maxPercent } : null
}

export async function saveWarmState(state: WarmState, path: string = warmStatePath()): Promise<void> {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 })
  await writeFileAtomic(path, JSON.stringify(state, null, 2))
}

/// Serializes read-modify-write of the state file within this process.
let stateQueue: Promise<unknown> = Promise.resolve()
export function updateWarmState(update: (state: WarmState) => WarmState, path: string = warmStatePath()): Promise<WarmState> {
  const next = stateQueue.then(async () => {
    const updated = update(await loadWarmState(path))
    await saveWarmState(updated, path)
    return updated
  })
  stateQueue = next.catch(() => {})
  return next
}

// ---------------------------------------------------------------- claude

/// The `claude` CLI on this machine: CODEBURN_CLAUDE_BIN, then PATH, then the
/// places its installers use (apps and services often run with a short PATH).
export async function findClaudeBinary(env: NodeJS.ProcessEnv = process.env, home: string = homedir()): Promise<string | null> {
  const name = process.platform === 'win32' ? 'claude.exe' : 'claude'
  const candidates = env.CODEBURN_CLAUDE_BIN
    ? [env.CODEBURN_CLAUDE_BIN]
    : [
        ...(env.PATH ?? '').split(delimiter).filter(Boolean).map(dir => join(dir, name)),
        join(home, '.local', 'bin', name),
        join(home, '.claude', 'local', name),
        join(home, '.npm-global', 'bin', name),
        '/opt/homebrew/bin/claude',
        '/usr/local/bin/claude',
      ]
  for (const candidate of candidates) {
    try {
      await access(candidate, constants.X_OK)
      return candidate
    } catch {}
  }
  return null
}

const NETWORK_RE = /ENOTFOUND|ECONNRESET|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN|fetch failed|network|connection error|socket hang up/i

function lastLine(text: string): string | null {
  const lines = text.split('\n').map(l => l.trim()).filter(Boolean)
  const line = lines[lines.length - 1]
  return line ? line.slice(0, 300) : null
}

/// One `claude -p` run in an empty temporary directory. API-key variables are
/// removed so Claude Code uses the subscription login, the only thing that has
/// a 5-hour window to start.
export async function sendWarmMessage(opts: { binary?: string | null; timeoutMs?: number } = {}): Promise<SendResult> {
  const binary = opts.binary === undefined ? await findClaudeBinary() : opts.binary
  if (!binary) return { ok: false, reason: 'claude_not_found', detail: null, network: false }
  const cwd = await mkdtemp(join(tmpdir(), 'codeburn-warm-'))
  const env = { ...process.env }
  delete env.ANTHROPIC_API_KEY
  delete env.ANTHROPIC_AUTH_TOKEN
  delete env.ANTHROPIC_BASE_URL
  try {
    return await new Promise<SendResult>((resolve) => {
      let out = ''
      let err = ''
      let settled = false
      const finish = (result: SendResult): void => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        resolve(result)
      }
      const child = spawn(binary, WARM_ARGS, { cwd, env, stdio: ['pipe', 'pipe', 'pipe'] })
      const timer = setTimeout(() => {
        child.kill('SIGTERM')
        finish({ ok: false, reason: 'send_failed', detail: 'Claude Code did not answer in time', network: true })
      }, opts.timeoutMs ?? SEND_TIMEOUT_MS)
      child.stdout.on('data', (chunk: Buffer) => { if (out.length < 64_000) out += chunk.toString() })
      child.stderr.on('data', (chunk: Buffer) => { if (err.length < 64_000) err += chunk.toString() })
      child.on('error', (e) => finish({ ok: false, reason: 'send_failed', detail: e.message, network: false }))
      child.on('close', (code) => {
        if (code === 0) {
          finish({ ok: true })
          return
        }
        const detail = lastLine(err) ?? lastLine(out) ?? `claude exited with code ${code}`
        finish({ ok: false, reason: 'send_failed', detail, network: NETWORK_RE.test(`${err}\n${out}`) })
      })
      child.stdin.on('error', () => {})
      child.stdin.end(WARM_PROMPT)
    })
  } finally {
    await rm(cwd, { recursive: true, force: true }).catch(() => {})
  }
}

/// The 5-hour window's state from Anthropic's usage endpoint (read-only, the
/// same reading as `codeburn quota` and the Plan view).
export async function readFiveHour(): Promise<FiveHourReading> {
  return readingOf(await fetchClaudeQuota({ allowKeychain: process.platform === 'darwin' }))
}

const SIGN_IN_HINT = 'run `claude` there and sign in with /login'

/// What a failed usage read means, in words that name the fix.
export function usageProblemOf(res: ClaudeResult): { problem: UsageProblem; detail: string } | null {
  const { quota } = res
  switch (quota.connection) {
    case 'connected':
      return null
    case 'disconnected':
      return { problem: 'signed_out', detail: `Claude Code is not signed in on this machine (${SIGN_IN_HINT})` }
    case 'accessDenied':
      return { problem: 'access_denied', detail: "the macOS Keychain refused access to Claude Code's login" }
    case 'terminalFailure':
      if (quota.footerLines.length > 0) {
        return { problem: 'login_expired', detail: `Claude Code's login expired and was not renewed (${SIGN_IN_HINT})` }
      }
      return { problem: 'rejected', detail: `the usage endpoint refused the request (HTTP ${res.httpStatus ?? '4xx'})` }
    default:
      if (res.retryAfterSeconds !== undefined) {
        return { problem: 'rate_limited', detail: `the usage endpoint is rate-limiting this machine (retry in ${res.retryAfterSeconds}s)` }
      }
      if (res.httpStatus === 401) return { problem: 'rejected', detail: 'the usage endpoint did not accept the login (HTTP 401)' }
      if (res.httpStatus !== undefined) return { problem: 'unreachable', detail: `the usage endpoint answered HTTP ${res.httpStatus}` }
      return { problem: 'unreachable', detail: `could not reach the usage endpoint${res.error ? `: ${res.error}` : ''}` }
  }
}

export function readingOf(res: ClaudeResult, now: number = Date.now()): FiveHourReading {
  const problem = usageProblemOf(res)
  if (problem) return { state: 'unknown', ...problem }
  const { quota } = res
  const five = quota.details.find(w => w.label === '5-hour')
  const weekly = quota.details.find(w => w.label === 'Weekly')
  if (!five) return { state: 'unknown', problem: 'no_five_hour', detail: 'the usage endpoint returned no 5-hour window' }
  if (weekly && weekly.percent >= 1) return { state: 'weekly_full', resetsAt: weekly.resetsAt }
  // Same rule as the Plan view: between windows the endpoint reports 0% and
  // no reset time.
  if (five.resetsAt === null && five.percent <= 0) return { state: 'idle' }
  // A reset time already past is a window that has ended; the endpoint can
  // lag a moment behind it.
  if (five.resetsAt !== null && Date.parse(five.resetsAt) <= now) return { state: 'idle' }
  return { state: 'running', resetsAt: five.resetsAt, percent: five.percent }
}

/// readFiveHour, with a running window folded into the tracked window.
export async function readAndTrack(statePath?: string, read: () => Promise<FiveHourReading> = readFiveHour): Promise<FiveHourReading> {
  const reading = await read()
  if (reading.state === 'running' && reading.resetsAt) {
    await updateWarmState(state => ({ ...state, currentWindow: trackWindow(state.currentWindow, reading) }), statePath).catch(() => {})
  }
  return reading
}

// ---------------------------------------------------------------- warm

export type WarmDeps = {
  readFiveHour: () => Promise<FiveHourReading>
  send: () => Promise<SendResult>
  sleep: (ms: number) => Promise<void>
  now: () => Date
}

const defaultDeps: WarmDeps = {
  readFiveHour,
  send: () => sendWarmMessage(),
  sleep: (ms) => new Promise(resolve => setTimeout(resolve, ms)),
  now: () => new Date(),
}

export type WarmOptions = {
  trigger: WarmTrigger
  /// Skip the idle check (the caller already knows the window is idle, or
  /// the user insists). Still exactly one message.
  force?: boolean
  slot?: string | null
}

/// Decides and, when idle, sends one warm. Never throws.
export async function performWarm(opts: WarmOptions, deps: Partial<WarmDeps> = {}): Promise<WarmResult> {
  const d = { ...defaultDeps, ...deps }
  const result = (outcome: WarmOutcome, reason: WarmReason | null, extra: Partial<WarmResult> = {}): WarmResult => ({
    at: d.now().toISOString(),
    trigger: opts.trigger,
    outcome,
    reason,
    detail: null,
    resetsAt: null,
    slot: opts.slot ?? null,
    ...extra,
  })
  const read = (): Promise<FiveHourReading> => d.readFiveHour().catch((e: unknown): FiveHourReading => ({
    state: 'unknown',
    problem: 'error',
    detail: e instanceof Error ? e.message : String(e),
  }))
  const skipUnlessIdle = async (): Promise<WarmResult | null> => {
    if (opts.force) return null
    let reading = await read()
    // A failed reading is often a blip (seen as a one-off "fetch failed");
    // a scheduled slot would be lost to it, so ask again before giving up.
    for (let i = 0; i < READ_RETRIES && reading.state === 'unknown'; i++) {
      await d.sleep(READ_RETRY_MS)
      reading = await read()
    }
    if (reading.state === 'idle') return null
    if (reading.state === 'running') return result('skipped', 'window_running', { resetsAt: reading.resetsAt })
    if (reading.state === 'weekly_full') return result('skipped', 'weekly_full', { resetsAt: reading.resetsAt })
    // Never warm blind: without a reading there is no telling whether a
    // window is already running.
    const detail = reading.detail ?? null
    if (reading.problem === 'signed_out' || reading.problem === 'login_expired') return result('skipped', 'signed_out', { detail })
    return result('skipped', 'usage_unavailable', { detail })
  }

  const skipped = await skipUnlessIdle()
  if (skipped) return skipped

  let sent = await d.send().catch((e: unknown): SendResult => ({ ok: false, reason: 'send_failed', detail: e instanceof Error ? e.message : String(e), network: false }))
  if (!sent.ok && sent.network && opts.trigger === 'scheduled') {
    // One retry for a network blip on a schedule; a person clicking Warm sees
    // the error at once instead.
    await d.sleep(NETWORK_RETRY_MS)
    const skippedOnRetry = await skipUnlessIdle()
    if (skippedOnRetry) return skippedOnRetry
    sent = await d.send().catch((e: unknown): SendResult => ({ ok: false, reason: 'send_failed', detail: e instanceof Error ? e.message : String(e), network: false }))
  }
  if (!sent.ok) return result('failed', sent.reason, { detail: sent.detail })
  if (opts.force) return result('started', null)

  for (let i = 0; i < CONFIRM_READS; i++) {
    await d.sleep(CONFIRM_INTERVAL_MS)
    const reading = await read()
    if (reading.state === 'running' && reading.resetsAt) return result('started', null, { resetsAt: reading.resetsAt })
  }
  // Claude answered, but the usage endpoint has not caught up (or the message
  // did not count toward the window). Reported, not hidden.
  return result('started', 'no_window_yet')
}

let inFlight: Promise<WarmResult> | null = null

export function isWarming(): boolean {
  return inFlight !== null
}

/// performWarm, one at a time per process, with the result appended to the
/// history. A request that arrives while a warm runs gets that warm's result
/// rather than sending a second message.
export function runWarm(opts: WarmOptions, deps: Partial<WarmDeps> = {}, statePath?: string, log: WarmLogger = warmLoggerFor(statePath)): Promise<WarmResult> {
  if (inFlight) return inFlight
  const run = (async () => {
    await log('info', 'warm.begin', { trigger: opts.trigger, slot: opts.slot ?? undefined, force: opts.force || undefined })
    // Every reading a warm takes also keeps the tracked window current.
    const res = await performWarm(opts, { readFiveHour: () => readAndTrack(statePath), ...deps })
    await log(levelOf(res), `warm.${res.outcome}`, {
      trigger: res.trigger,
      reason: res.reason ?? undefined,
      resetsAt: res.resetsAt ?? undefined,
      detail: res.detail ?? undefined,
    })
    await updateWarmState(state => ({ ...state, history: [res, ...state.history].slice(0, HISTORY_LIMIT) }), statePath).catch(() => {})
    return res
  })()
  inFlight = run
  void run.finally(() => {
    inFlight = null
  })
  return run
}

export function warmLoggerFor(statePath: string = warmStatePath()): WarmLogger {
  return createWarmLogger(warmLogPathFor(statePath))
}

/// A skip the user has to act on is a warning; a send that failed, an error.
function levelOf(res: WarmResult): WarmLogLevel {
  if (res.outcome === 'failed') return 'error'
  if (res.reason === 'signed_out' || res.reason === 'usage_unavailable' || res.reason === 'no_window_yet') return 'warn'
  return 'info'
}

/// The window a warm at `resetsAt` started, for display.
export function windowStartOf(resetsAt: string): string {
  return new Date(Date.parse(resetsAt) - WINDOW_MS).toISOString()
}

// ---------------------------------------------------------------- scheduler

export type WarmScheduler = { stop: () => void; tick: () => Promise<void> }

/// Checks the stored schedule every `intervalMs` and fires each due slot once.
/// With auto-warm on it also reads usage every 15 minutes, to learn when the
/// current window resets, and warms right after that reset. A slot or reset is
/// marked fired before the warm runs, so a crash mid-warm never sends twice.
export function startWarmScheduler(opts: {
  statePath?: string
  now?: () => Date
  intervalMs?: number
  pollMs?: number
  warm?: (slot: string, trigger: 'scheduled' | 'auto') => Promise<unknown>
  read?: () => Promise<FiveHourReading>
  log?: WarmLogger
} = {}): WarmScheduler {
  const now = opts.now ?? (() => new Date())
  const log = opts.log ?? warmLoggerFor(opts.statePath)
  const warm = opts.warm ?? ((slot: string, trigger: 'scheduled' | 'auto') => runWarm({ trigger, slot }, {}, opts.statePath, log))
  const read = opts.read ?? readFiveHour
  const pollMs = opts.pollMs ?? AUTO_POLL_MS
  let lastPoll = -Infinity
  // Auto-warm polls every 15 minutes; a problem is logged when it starts,
  // changes or clears, not on every poll.
  let pollProblem: string | null = null
  const notePoll = async (reading: FiveHourReading): Promise<void> => {
    const problem = reading.state === 'unknown' ? (reading.problem ?? 'error') : null
    if (problem === pollProblem) return
    if (problem && reading.state === 'unknown') {
      await log('warn', 'usage.unreadable', { problem, detail: reading.detail ?? undefined, note: 'auto-warm cannot see resets until this clears' })
    } else {
      await log('info', 'usage.readable', { state: reading.state })
    }
    pollProblem = problem
  }
  let current: Promise<void> | null = null
  const markFired = (key: string): Promise<WarmState> =>
    updateWarmState(s => ({ ...s, firedSlots: [key, ...s.firedSlots.filter(x => x !== key)].slice(0, FIRED_SLOTS_LIMIT) }), opts.statePath)
  const check = async (): Promise<void> => {
    try {
      let state = await loadWarmState(opts.statePath)
      if (!state.schedule) return
      const at = now()
      const due = dueSlot(state.schedule, at)
      if (due && !state.firedSlots.includes(due.slot)) {
        await markFired(due.slot)
        await log('info', 'schedule.due', { slot: due.slot })
        await warm(due.slot, 'scheduled')
        return
      }
      if (!state.schedule.auto.enabled) return
      if (at.getTime() - lastPoll >= pollMs && !isWarming()) {
        lastPoll = at.getTime()
        const reading = await readAndTrack(opts.statePath, read).catch((e: unknown): FiveHourReading => ({
          state: 'unknown',
          problem: 'error',
          detail: e instanceof Error ? e.message : String(e),
        }))
        await notePoll(reading)
        state = await loadWarmState(opts.statePath)
      }
      const auto = dueAutoWarm(state, at)
      if (!auto) return
      await markFired(auto.key)
      await log('info', 'auto.due', { reset: auto.resetsAt })
      await warm(auto.key, 'auto')
    } catch (e) {
      // A bad state file or a failed warm must never stop the scheduler.
      await log('error', 'scheduler.error', { detail: e instanceof Error ? e.message : String(e) })
    }
  }
  // A tick while one runs (a long warm) joins it rather than starting another.
  const tick = (): Promise<void> => {
    current ??= check().finally(() => {
      current = null
    })
    return current
  }
  const timer = setInterval(() => void tick(), opts.intervalMs ?? 30_000)
  timer.unref?.()
  void tick()
  return { stop: () => clearInterval(timer), tick }
}

// ---------------------------------------------------------------- status

export type WarmStatus = {
  version: number
  /// Whether this device accepts warm requests from paired devices
  /// (`codeburn share --allow-warm`). Always true for the local CLI.
  allowed: boolean
  claudeFound: boolean
  /// Whether Claude Code has a stored login here; null where it cannot be
  /// told without reading the keychain (macOS).
  signedIn: boolean | null
  warming: boolean
  timeZone: string
  schedule: WarmSchedule | null
  history: WarmResult[]
  /// The window auto-warm is watching, with its highest reading.
  currentWindow: TrackedWindow | null
}

/// Whether Claude Code's credentials file holds a login. Signing out (or a
/// failed renewal) leaves the file in place with empty tokens, so the file
/// existing is not enough.
export async function hasStoredLogin(path: string): Promise<boolean> {
  try {
    const raw = JSON.parse(await readFile(path, 'utf8')) as { claudeAiOauth?: Record<string, unknown> }
    const oauth = raw.claudeAiOauth
    const filled = (v: unknown): boolean => typeof v === 'string' && v.length > 0
    return !!oauth && (filled(oauth.accessToken) || filled(oauth.refreshToken))
  } catch {
    return false
  }
}

export async function buildWarmStatus(opts: { allowed: boolean; statePath?: string; env?: NodeJS.ProcessEnv; home?: string }): Promise<WarmStatus> {
  const env = opts.env ?? process.env
  const home = opts.home ?? homedir()
  const [state, binary] = await Promise.all([loadWarmState(opts.statePath), findClaudeBinary(env, home)])
  let signedIn: boolean | null = null
  if (process.platform !== 'darwin') {
    const configDir = env.CLAUDE_CONFIG_DIR || join(home, '.claude')
    signedIn = await hasStoredLogin(join(configDir, '.credentials.json'))
  }
  return {
    version: WARM_STATUS_VERSION,
    allowed: opts.allowed,
    claudeFound: binary !== null,
    signedIn,
    warming: isWarming(),
    timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    schedule: state.schedule,
    history: state.history,
    currentWindow: state.currentWindow,
  }
}

/// Replaces the stored schedule. Returns null when the input is not valid.
export async function setWarmSchedule(input: unknown, statePath?: string): Promise<WarmSchedule | null> {
  const schedule = parseSchedule(input)
  if (!schedule) return null
  await updateWarmState(state => ({ ...state, schedule }), statePath)
  return schedule
}
