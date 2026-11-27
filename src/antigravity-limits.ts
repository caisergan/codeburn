// `codeburn limits --provider antigravity`: Antigravity 5-hour sessions and
// weeks at API prices, one report per quota group.
//
// Antigravity meters its models in groups ("Gemini Models", "Claude and GPT
// models"); the models of a group share a 5-hour and a weekly limit. The menu
// bar logs every quota check to `antigravity-limit-readings.jsonl`; this module
// turns those readings and the locally priced Antigravity calls into the same
// sessions-and-weeks report `codeburn limits` gives for Claude, once per group.
// No network calls. See docs/design/antigravity-session-usage.md.

import { readFile } from 'fs/promises'
import { join } from 'path'

import { getCodeburnCacheDir } from './cache-dir.js'
import { collectLimitCalls, collectLimitPrompts } from './claude-limit-sources.js'
import {
  computeClaudeLimits,
  FIVE_HOURS_MS,
  MINUTE_MS,
  WEEK_LIST_COUNT,
  WEEK_MS,
  type FailedCheck,
  type LimitCall,
  type LimitPrompt,
  type LimitReading,
  type LimitsOutput,
  type WindowReading,
} from './claude-limits.js'
import { parseAllSessions } from './parser.js'
import type { ProjectSummary } from './types.js'

export const ANTIGRAVITY_READING_LOG_FILE = 'antigravity-limit-readings.jsonl'

/// Enough history for the current week, the three before it, and the week
/// before those (the per-session estimates fall back to it).
export const ANTIGRAVITY_LOOKBACK_MS = (WEEK_LIST_COUNT + 1) * WEEK_MS + 24 * 60 * 60 * 1000

/// Antigravity starts a window on the first message, to the second, and
/// reports its reset 0–2 s after that message's timestamp (measured
/// 2026-11-27: a weekly reset at 15:04:49 for a first call at 15:04:48.97, a
/// 5-hour reset at 02:02:39 for one at 21:02:37.6). Windows are keyed to the
/// minute and moved one minute earlier, so the call that opened a window
/// always falls inside it.
const STEP_MS = MINUTE_MS
const RESET_LEAD_MS = MINUTE_MS

/// An unused bucket reads full with a reset that keeps sliding to "now + the
/// window"; such a reading names a window nobody started.
const IDLE_PCT = 0.5
const IDLE_SLIDE_SLACK_MS = 3 * MINUTE_MS

export type GroupReading = {
  id: string
  name: string
  models: string[]
  fiveHour?: WindowReading
  sevenDay?: WindowReading
}

export type AntigravityReading = {
  at: number
  plan?: string
  groups: GroupReading[]
}

export type AntigravityGroupOut = {
  id: string
  name: string
  /// Display names of the group's models, from the latest reading.
  models: string[]
  report: LimitsOutput
}

export type AntigravityLimitsOutput = {
  generatedAt: string
  plan: string | null
  readingsThrough: string | null
  groups: AntigravityGroupOut[]
}

// ---------------------------------------------------------------------------
// Reading log
// ---------------------------------------------------------------------------

function num(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

function time(value: unknown): number | undefined {
  if (typeof value === 'number' && Number.isFinite(value)) return value < 1e12 ? value * 1000 : value
  if (typeof value !== 'string') return undefined
  const ms = Date.parse(value)
  return Number.isFinite(ms) ? ms : undefined
}

/// A bucket reading, or undefined when it has no reset time or reads idle.
function bucket(value: unknown, at: number, windowMs: number): WindowReading | undefined {
  if (!value || typeof value !== 'object') return undefined
  const row = value as Record<string, unknown>
  const pct = num(row['pct'])
  const resetsAt = time(row['resetsAt'])
  if (pct === undefined || resetsAt === undefined) return undefined
  if (pct < IDLE_PCT && resetsAt - at >= windowMs - IDLE_SLIDE_SLACK_MS) return undefined
  return { pct, resetsAt }
}

/// One log line, or null for anything malformed (a torn final line included).
export function parseAntigravityReadingLine(line: string): { reading?: AntigravityReading; failure?: FailedCheck } | null {
  let row: unknown
  try {
    row = JSON.parse(line)
  } catch {
    return null
  }
  if (!row || typeof row !== 'object') return null
  const r = row as Record<string, unknown>
  const at = time(r['at'])
  if (at === undefined) return null
  if (r['ok'] === false) {
    const reason = typeof r['reason'] === 'string' ? r['reason'] : 'network'
    return { failure: { at, reason } }
  }
  if (r['ok'] !== true || !Array.isArray(r['groups'])) return null
  const groups: GroupReading[] = []
  for (const raw of r['groups'] as unknown[]) {
    if (!raw || typeof raw !== 'object') continue
    const g = raw as Record<string, unknown>
    const id = typeof g['id'] === 'string' && g['id'] ? g['id'] : undefined
    if (!id) continue
    const fiveHour = bucket(g['five_hour'], at, FIVE_HOURS_MS)
    const sevenDay = bucket(g['seven_day'], at, WEEK_MS)
    groups.push({
      id,
      name: typeof g['name'] === 'string' && g['name'] ? g['name'] : id,
      models: Array.isArray(g['models']) ? (g['models'] as unknown[]).filter((m): m is string => typeof m === 'string') : [],
      ...(fiveHour ? { fiveHour } : {}),
      ...(sevenDay ? { sevenDay } : {}),
    })
  }
  return {
    reading: {
      at,
      ...(typeof r['plan'] === 'string' && r['plan'] ? { plan: r['plan'] } : {}),
      groups,
    },
  }
}

export async function readAntigravityReadingLog(
  path = join(getCodeburnCacheDir(), ANTIGRAVITY_READING_LOG_FILE),
): Promise<{ readings: AntigravityReading[]; failures: FailedCheck[] }> {
  let text: string
  try {
    text = await readFile(path, 'utf-8')
  } catch {
    return { readings: [], failures: [] }
  }
  const readings: AntigravityReading[] = []
  const failures: FailedCheck[] = []
  for (const line of text.split('\n')) {
    if (!line.trim()) continue
    const parsed = parseAntigravityReadingLine(line)
    if (parsed?.reading) readings.push(parsed.reading)
    if (parsed?.failure) failures.push(parsed.failure)
  }
  return { readings, failures }
}

// ---------------------------------------------------------------------------
// Groups
// ---------------------------------------------------------------------------

type Family = 'gemini' | 'claude' | 'gpt' | 'other'

export function modelFamily(model: string): Family {
  const m = model.toLowerCase()
  if (m.includes('gemini')) return 'gemini'
  if (m.includes('claude') || m.includes('opus') || m.includes('sonnet') || m.includes('haiku')) return 'claude'
  if (m.includes('gpt')) return 'gpt'
  return 'other'
}

type GroupInfo = { id: string; name: string; models: string[] }

/// The families a group meters: from its model list, else from its id/name.
function groupFamilies(group: GroupInfo): Set<Family> {
  const families = new Set<Family>(group.models.map(modelFamily).filter(f => f !== 'other'))
  if (families.size === 0) {
    const label = `${group.id} ${group.name}`.toLowerCase()
    for (const f of ['gemini', 'claude', 'gpt'] as const) if (label.includes(f)) families.add(f)
  }
  return families
}

/// The group whose limits a model spends: the one that lists its family;
/// failing that, a model that is not Gemini goes to the group that is not
/// Gemini's ("Claude and GPT models", id `3p`).
export function groupForModel(model: string, groups: GroupInfo[]): string | undefined {
  const family = modelFamily(model)
  const listed = groups.find(g => groupFamilies(g).has(family))
  if (listed) return listed.id
  if (family === 'gemini') return groups.find(g => g.id === 'gemini')?.id
  return groups.find(g => !groupFamilies(g).has('gemini'))?.id
}

/// The groups as the newest reading names them. Before any reading, the two
/// groups Antigravity has today, so spend still shows per inferred session.
function knownGroups(readings: AntigravityReading[]): GroupInfo[] {
  const byId = new Map<string, GroupInfo>()
  for (const r of readings) {
    for (const g of r.groups) byId.set(g.id, { id: g.id, name: g.name, models: g.models.length > 0 ? g.models : byId.get(g.id)?.models ?? [] })
  }
  if (byId.size > 0) return [...byId.values()]
  return [
    { id: 'gemini', name: 'Gemini Models', models: [] },
    { id: '3p', name: 'Claude and GPT models', models: [] },
  ]
}

function shift(reading: WindowReading | undefined): WindowReading | undefined {
  return reading ? { pct: reading.pct, resetsAt: reading.resetsAt - RESET_LEAD_MS } : undefined
}

/// One group's readings in the shape the Claude math takes.
function groupReadings(readings: AntigravityReading[], id: string): LimitReading[] {
  const out: LimitReading[] = []
  for (const r of readings) {
    const g = r.groups.find(x => x.id === id)
    if (!g) continue
    const fiveHour = shift(g.fiveHour)
    const sevenDay = shift(g.sevenDay)
    out.push({
      at: r.at,
      ...(r.plan ? { plan: r.plan } : {}),
      ...(fiveHour ? { fiveHour } : {}),
      ...(sevenDay ? { sevenDay } : {}),
    })
  }
  return out
}

export type AntigravityLimitsInput = {
  now: number
  readings: AntigravityReading[]
  failures: FailedCheck[]
  calls: LimitCall[]
  prompts?: LimitPrompt[]
}

export function computeAntigravityLimits(input: AntigravityLimitsInput): AntigravityLimitsOutput {
  const readings = [...input.readings].sort((a, b) => a.at - b.at)
  const groups = knownGroups(readings)
  const callsByGroup = new Map<string, LimitCall[]>()
  for (const call of input.calls) {
    const id = groupForModel(call.model, groups)
    if (!id) continue
    const list = callsByGroup.get(id) ?? []
    list.push(call)
    callsByGroup.set(id, list)
  }
  const prompts = input.prompts ?? []
  const out: AntigravityGroupOut[] = groups.map(g => {
    const calls = callsByGroup.get(g.id) ?? []
    const chats = new Set(calls.map(c => c.chatId))
    return {
      id: g.id,
      name: g.name,
      models: g.models,
      report: computeClaudeLimits({
        now: input.now,
        readings: groupReadings(readings, g.id),
        failures: input.failures,
        events: [],
        calls,
        prompts: prompts.filter(p => chats.has(p.chatId)),
        windowStepMs: STEP_MS,
      }),
    }
  })
  const plan = [...readings].reverse().find(r => r.plan)?.plan ?? null
  const last = readings.at(-1)
  return {
    generatedAt: new Date(input.now).toISOString(),
    plan,
    readingsThrough: last ? new Date(last.at).toISOString() : null,
    groups: out,
  }
}

/// Antigravity's chats are not tied to a folder CodeBurn can `cd` into: the
/// project is the app it came from ("antigravity-cli").
function flattenCalls(projects: ProjectSummary[]): { calls: LimitCall[]; prompts: LimitPrompt[] } {
  const calls = collectLimitCalls(projects).map(c => {
    const { chatPath: _path, ...rest } = c
    return rest
  })
  return { calls, prompts: collectLimitPrompts(projects) }
}

export async function buildAntigravityLimitsReport(now = new Date()): Promise<AntigravityLimitsOutput> {
  // Whole local days, as `limits` does for Claude, so the parse memo is reused.
  const lookbackStart = new Date(now.getTime() - ANTIGRAVITY_LOOKBACK_MS)
  const start = new Date(lookbackStart.getFullYear(), lookbackStart.getMonth(), lookbackStart.getDate())
  const end = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 23, 59, 59, 999)
  const since = start.getTime()
  const [log, projects] = await Promise.all([
    readAntigravityReadingLog(),
    parseAllSessions({ start, end }, 'antigravity'),
  ])
  const { calls, prompts } = flattenCalls(projects)
  return computeAntigravityLimits({
    now: now.getTime(),
    readings: log.readings.filter(r => r.at >= since),
    failures: log.failures.filter(f => f.at >= since),
    calls,
    prompts,
  })
}
