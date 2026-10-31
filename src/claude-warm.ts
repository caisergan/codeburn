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
import { getConfigFilePath } from './config.js'
import { fetchClaudeQuota } from './quota/claude.js'

export const WARM_STATUS_VERSION = 1
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

/// 0 = Monday … 6 = Sunday.
export type WarmSchedule = {
  enabled: boolean
  /// Local "HH:MM" times on 10-minute marks, sorted, at most MAX_WARM_TIMES.
  times: string[]
  days: number[]
  /// IANA zone the times are in (the Mac's), so a runner in UTC fires at the
  /// user's local time.
  timeZone: string
}

export type WarmTrigger = 'manual' | 'scheduled'
export type WarmOutcome = 'started' | 'skipped' | 'failed'
/// Machine-readable why, localized by the app.
export type WarmReason =
  | 'window_running'
  | 'weekly_full'
  | 'usage_unavailable'
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
  /// "YYYY-MM-DD HH:MM" in the schedule's zone, for scheduled warms.
  slot: string | null
}

export type WarmState = {
  schedule: WarmSchedule | null
  history: WarmResult[]
  firedSlots: string[]
}

export type FiveHourReading =
  | { state: 'idle' }
  | { state: 'running'; resetsAt: string | null }
  | { state: 'weekly_full'; resetsAt: string | null }
  | { state: 'unknown' }

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
  return {
    enabled: raw.enabled,
    times: [...minutes].sort((a, b) => a - b).map(hhmm),
    days: [...days].sort((a, b) => a - b),
    timeZone: raw.timeZone,
  }
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
    }
  } catch {
    return { schedule: null, history: [], firedSlots: [] }
  }
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
  const { quota } = await fetchClaudeQuota({ allowKeychain: process.platform === 'darwin' })
  if (quota.connection !== 'connected') return { state: 'unknown' }
  const five = quota.details.find(w => w.label === '5-hour')
  const weekly = quota.details.find(w => w.label === 'Weekly')
  if (!five) return { state: 'unknown' }
  if (weekly && weekly.percent >= 1) return { state: 'weekly_full', resetsAt: weekly.resetsAt }
  // Same rule as the Plan view: between windows the endpoint reports 0% and
  // no reset time.
  if (five.resetsAt === null && five.percent <= 0) return { state: 'idle' }
  return { state: 'running', resetsAt: five.resetsAt }
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
  const read = (): Promise<FiveHourReading> => d.readFiveHour().catch((): FiveHourReading => ({ state: 'unknown' }))
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
    return result('skipped', 'usage_unavailable')
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
export function runWarm(opts: WarmOptions, deps: Partial<WarmDeps> = {}, statePath?: string): Promise<WarmResult> {
  if (inFlight) return inFlight
  const run = (async () => {
    const res = await performWarm(opts, deps)
    await updateWarmState(state => ({ ...state, history: [res, ...state.history].slice(0, HISTORY_LIMIT) }), statePath).catch(() => {})
    return res
  })()
  inFlight = run
  void run.finally(() => {
    inFlight = null
  })
  return run
}

/// The window a warm at `resetsAt` started, for display.
export function windowStartOf(resetsAt: string): string {
  return new Date(Date.parse(resetsAt) - WINDOW_MS).toISOString()
}

// ---------------------------------------------------------------- scheduler

export type WarmScheduler = { stop: () => void; tick: () => Promise<void> }

/// Checks the stored schedule every `intervalMs` and fires each due slot once.
/// A slot is marked fired before the warm runs, so a crash mid-warm never
/// sends twice.
export function startWarmScheduler(opts: {
  statePath?: string
  now?: () => Date
  intervalMs?: number
  warm?: (slot: string) => Promise<unknown>
} = {}): WarmScheduler {
  const now = opts.now ?? (() => new Date())
  const warm = opts.warm ?? ((slot: string) => runWarm({ trigger: 'scheduled', slot }, {}, opts.statePath))
  let current: Promise<void> | null = null
  const check = async (): Promise<void> => {
    try {
      const state = await loadWarmState(opts.statePath)
      if (!state.schedule) return
      const due = dueSlot(state.schedule, now())
      if (!due || state.firedSlots.includes(due.slot)) return
      await updateWarmState(s => ({ ...s, firedSlots: [due.slot, ...s.firedSlots.filter(x => x !== due.slot)].slice(0, FIRED_SLOTS_LIMIT) }), opts.statePath)
      await warm(due.slot)
    } catch {
      // A bad state file or a failed warm must never stop the scheduler.
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
}

export async function buildWarmStatus(opts: { allowed: boolean; statePath?: string; env?: NodeJS.ProcessEnv; home?: string }): Promise<WarmStatus> {
  const env = opts.env ?? process.env
  const home = opts.home ?? homedir()
  const [state, binary] = await Promise.all([loadWarmState(opts.statePath), findClaudeBinary(env, home)])
  let signedIn: boolean | null = null
  if (process.platform !== 'darwin') {
    const configDir = env.CLAUDE_CONFIG_DIR || join(home, '.claude')
    signedIn = await access(join(configDir, '.credentials.json'), constants.R_OK).then(() => true, () => false)
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
  }
}

/// Replaces the stored schedule. Returns null when the input is not valid.
export async function setWarmSchedule(input: unknown, statePath?: string): Promise<WarmSchedule | null> {
  const schedule = parseSchedule(input)
  if (!schedule) return null
  await updateWarmState(state => ({ ...state, schedule }), statePath)
  return schedule
}
