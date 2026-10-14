// The inputs `codeburn limits` reads: the reading log the menubar writes, the
// refused requests in Claude Code transcripts, and the priced Claude calls.
// No network calls; without the log it still reports spend per inferred
// session and limit-hit times.

import { createReadStream } from 'fs'
import { mkdir, open, readFile, readdir, rename, stat, unlink } from 'fs/promises'
import { randomBytes } from 'crypto'
import { join, resolve } from 'path'

import { getCodeburnCacheDir } from './cache-dir.js'
import type { FailedCheck, LimitCall, LimitEvent, LimitName, LimitReading } from './claude-limits.js'
import { findUnpricedModels } from './models.js'
import type { ProjectSummary } from './types.js'

export const READING_LOG_FILE = 'claude-limit-readings.jsonl'
const EVENTS_CACHE_FILE = 'claude-limit-events-cache.json'
const EVENTS_CACHE_VERSION = 1

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

function windowReading(value: unknown): { pct: number; resetsAt: number } | undefined {
  if (!value || typeof value !== 'object') return undefined
  const row = value as Record<string, unknown>
  const pct = num(row['pct'])
  const resetsAt = time(row['resetsAt'])
  return pct === undefined || resetsAt === undefined ? undefined : { pct, resetsAt }
}

/// One log line, or null for anything malformed (a torn final line included).
export function parseReadingLine(line: string): { reading?: LimitReading; failure?: FailedCheck } | null {
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
    const retryAfter = num(r['retryAfter'])
    return { failure: { at, reason, ...(retryAfter !== undefined ? { retryAfter } : {}) } }
  }
  if (r['ok'] !== true) return null
  const fiveHour = windowReading(r['five_hour'])
  const sevenDay = windowReading(r['seven_day'])
  return {
    reading: {
      at,
      ...(typeof r['plan'] === 'string' && r['plan'] ? { plan: r['plan'] } : {}),
      ...(fiveHour ? { fiveHour } : {}),
      ...(sevenDay ? { sevenDay } : {}),
      ...(r['imported'] === true ? { imported: true } : {}),
    },
  }
}

export async function readReadingLog(
  path = join(getCodeburnCacheDir(), READING_LOG_FILE),
): Promise<{ readings: LimitReading[]; failures: FailedCheck[] }> {
  let text: string
  try {
    text = await readFile(path, 'utf-8')
  } catch {
    return { readings: [], failures: [] }
  }
  const readings: LimitReading[] = []
  const failures: FailedCheck[] = []
  for (const line of text.split('\n')) {
    if (!line.trim()) continue
    const parsed = parseReadingLine(line)
    if (parsed?.reading) readings.push(parsed.reading)
    if (parsed?.failure) failures.push(parsed.failure)
  }
  return { readings, failures }
}

// ---------------------------------------------------------------------------
// Refused requests
// ---------------------------------------------------------------------------

/// A Claude Code record for a request refused at a limit. Claude Code writes a
/// synthetic assistant message with `error: "rate_limit"` and the limit that
/// refused it in `quotaLimits` (`resetsAt` in epoch seconds).
export function parseLimitEventLine(line: string): LimitEvent | null {
  if (!line.includes('"quotaLimits"')) return null
  let row: unknown
  try {
    row = JSON.parse(line)
  } catch {
    return null
  }
  if (!row || typeof row !== 'object') return null
  const r = row as Record<string, unknown>
  const quota = r['quotaLimits']
  if (!quota || typeof quota !== 'object') return null
  const q = quota as Record<string, unknown>
  if (q['status'] !== 'rejected') return null
  const limit = q['rateLimitType']
  if (limit !== 'five_hour' && limit !== 'seven_day') return null
  const at = time(r['timestamp'])
  const resetsAt = time(q['resetsAt'])
  if (at === undefined || resetsAt === undefined) return null
  return { limit: limit as LimitName, at, resetsAt }
}

type FileEntry = { offset: number; size: number; mtimeMs: number; events: LimitEvent[] }
type EventsCache = { version: number; files: Record<string, FileEntry> }

async function loadEventsCache(path: string): Promise<EventsCache> {
  try {
    const parsed = JSON.parse(await readFile(path, 'utf-8')) as EventsCache
    if (parsed && parsed.version === EVENTS_CACHE_VERSION && parsed.files && typeof parsed.files === 'object') return parsed
  } catch {}
  return { version: EVENTS_CACHE_VERSION, files: {} }
}

async function writeFileAtomic(finalPath: string, payload: string): Promise<void> {
  const tempPath = `${finalPath}.${randomBytes(8).toString('hex')}.tmp`
  const handle = await open(tempPath, 'w', 0o600)
  try {
    await handle.writeFile(payload, { encoding: 'utf-8' })
  } finally {
    await handle.close()
  }
  try {
    await rename(tempPath, finalPath)
  } catch (err) {
    try { await unlink(tempPath) } catch {}
    throw err
  }
}

async function listTranscripts(projectsDir: string, sinceMs: number): Promise<Array<{ path: string; size: number; mtimeMs: number }>> {
  const out: Array<{ path: string; size: number; mtimeMs: number }> = []
  async function walk(dir: string, depth: number): Promise<void> {
    let entries: import('fs').Dirent[]
    try {
      entries = await readdir(dir, { withFileTypes: true })
    } catch {
      return
    }
    for (const entry of entries) {
      const path = join(dir, entry.name)
      if (entry.isDirectory()) {
        // projects/<slug>/<session>/subagents/agent-*.jsonl is the deepest layout.
        if (depth < 3) await walk(path, depth + 1)
        continue
      }
      if (!entry.name.endsWith('.jsonl')) continue
      try {
        const info = await stat(path)
        if (info.mtimeMs >= sinceMs) out.push({ path, size: info.size, mtimeMs: info.mtimeMs })
      } catch {}
    }
  }
  await walk(projectsDir, 0)
  return out
}

/// Read complete lines from `offset`, returning the events and the offset just
/// past the last complete line (a line still being written is read next time).
/// Only lines that mention `quotaLimits` are decoded.
async function scanFrom(path: string, offset: number): Promise<{ events: LimitEvent[]; offset: number }> {
  const events: LimitEvent[] = []
  const needle = Buffer.from('"quotaLimits"')
  let consumed = offset
  let carry: Buffer = Buffer.alloc(0)
  for await (const chunk of createReadStream(path, { start: offset })) {
    const buf: Buffer = carry.length > 0 ? Buffer.concat([carry, chunk as Buffer]) : chunk as Buffer
    let lineStart = 0
    for (let nl = buf.indexOf(0x0a, lineStart); nl !== -1; nl = buf.indexOf(0x0a, lineStart)) {
      const line = buf.subarray(lineStart, nl)
      if (line.indexOf(needle) !== -1) {
        const event = parseLimitEventLine(line.toString('utf-8'))
        if (event) events.push(event)
      }
      consumed += nl + 1 - lineStart
      lineStart = nl + 1
    }
    carry = Buffer.from(buf.subarray(lineStart))
  }
  return { events, offset: consumed }
}

/// A resident `codeburn serve` answers `limits` every couple of minutes; the
/// walk and stat of every recent transcript is most of what a warm answer
/// costs. A limit hit therefore shows up within this long, which the 5-hour
/// reading taken at the same tick already covers to the percent.
const EVENTS_MEMO_MS = 60 * 1000
let eventsMemo: { key: string; at: number; events: LimitEvent[] } | null = null

/// Test seam: forget the in-process memo.
export function clearLimitEventsMemo(): void {
  eventsMemo = null
}

/// Refused requests from transcripts written since `sinceMs`, read
/// incrementally: transcripts are append-only, so a grown file is read from
/// where the last scan stopped.
export async function collectLimitEvents(claudeDirs: string[], sinceMs: number, cacheDir = getCodeburnCacheDir(), now = Date.now()): Promise<LimitEvent[]> {
  const key = `${claudeDirs.join('\0')}\0${cacheDir}`
  if (eventsMemo && eventsMemo.key === key && now - eventsMemo.at < EVENTS_MEMO_MS) {
    return eventsMemo.events.filter(e => e.at >= sinceMs)
  }
  const events = await scanLimitEvents(claudeDirs, sinceMs, cacheDir)
  eventsMemo = { key, at: now, events }
  return events
}

async function scanLimitEvents(claudeDirs: string[], sinceMs: number, cacheDir: string): Promise<LimitEvent[]> {
  const cachePath = join(cacheDir, EVENTS_CACHE_FILE)
  const cache = await loadEventsCache(cachePath)
  const next: EventsCache = { version: EVENTS_CACHE_VERSION, files: {} }
  let changed = false
  const events: LimitEvent[] = []
  for (const dir of claudeDirs) {
    for (const file of await listTranscripts(join(resolve(dir), 'projects'), sinceMs)) {
      const prior = cache.files[file.path]
      let entry: FileEntry
      if (prior && prior.size === file.size && prior.mtimeMs === file.mtimeMs) {
        entry = prior
      } else {
        const grown = prior && file.size >= prior.offset
        try {
          const scanned = await scanFrom(file.path, grown ? prior.offset : 0)
          entry = {
            offset: scanned.offset,
            size: file.size,
            mtimeMs: file.mtimeMs,
            events: [...(grown ? prior.events : []), ...scanned.events],
          }
        } catch {
          continue
        }
        changed = true
      }
      next.files[file.path] = entry
      events.push(...entry.events)
    }
  }
  if (changed || Object.keys(cache.files).length !== Object.keys(next.files).length) {
    try {
      await mkdir(cacheDir, { recursive: true })
      await writeFileAtomic(cachePath, JSON.stringify(next))
    } catch {}
  }
  return events.filter(e => e.at >= sinceMs)
}

// ---------------------------------------------------------------------------
// Calls
// ---------------------------------------------------------------------------

const MAX_TITLE = 80

function clean(text: string): string {
  return text.replace(/[\x00-\x1F\x7F-\x9F]/g, ' ').replace(/\s+/g, ' ').trim()
}

function projectLabel(path: string, fallback: string): string {
  const segments = path.replace(/\\/g, '/').replace(/\/+$/, '').split('/').filter(Boolean)
  return segments.at(-1) ?? fallback
}

// A resident serve process hands back the same memoized ProjectSummary array
// while the session roots are quiet, so the flattening is memoized on it too.
const callsMemo = new WeakMap<ProjectSummary[], { dir: string | undefined; calls: LimitCall[] }>()

/// Every priced Claude call, with the chat it belongs to. Subagents fold into
/// their parent chat. A chat's title is its own title, else its project plus
/// the start of its first prompt.
export function collectLimitCalls(projects: ProjectSummary[], defaultClaudeDir?: string): LimitCall[] {
  const memo = callsMemo.get(projects)
  if (memo && memo.dir === defaultClaudeDir) return memo.calls
  const calls = flattenLimitCalls(projects, defaultClaudeDir)
  callsMemo.set(projects, { dir: defaultClaudeDir, calls })
  return calls
}

function flattenLimitCalls(projects: ProjectSummary[], defaultClaudeDir?: string): LimitCall[] {
  const unpricedMemo = new Map<string, boolean>()
  const isUnpriced = (model: string, cost: number): boolean => {
    if (cost > 0) return false
    let unpriced = unpricedMemo.get(model)
    if (unpriced === undefined) {
      unpriced = findUnpricedModels([{ model, calls: 1, cost: 0 }]).length > 0
      unpricedMemo.set(model, unpriced)
    }
    return unpriced
  }

  const titles = new Map<string, string>()
  for (const project of projects) {
    for (const session of project.sessions) {
      if (session.isSidechain) continue
      const own = session.title ? clean(session.title) : ''
      const first = session.turns.find(t => t.userMessage && t.userMessage.trim())?.userMessage ?? ''
      const label = projectLabel(project.projectPath, session.project || project.project)
      const title = own || (first ? `${label} · “${clean(first)}”` : label)
      titles.set(session.sessionId, Array.from(title).slice(0, MAX_TITLE).join(''))
    }
  }

  const out: LimitCall[] = []
  const defaultDir = defaultClaudeDir ? resolve(defaultClaudeDir) : undefined
  for (const project of projects) {
    for (const session of project.sessions) {
      // V1 follows the default account: sessions from another configured
      // Claude directory belong to readings this Mac does not take.
      if (defaultDir && session.source?.kind === 'claude-config' && resolve(session.source.path) !== defaultDir) continue
      const chatId = session.parentSessionId ?? session.sessionId
      const chatTitle = titles.get(chatId) ?? titles.get(session.sessionId)
        ?? projectLabel(project.projectPath, session.project || project.project)
      for (const turn of session.turns) {
        for (const call of turn.assistantCalls) {
          const at = Date.parse(call.timestamp)
          if (!Number.isFinite(at)) continue
          if (call.model === '<synthetic>') continue
          out.push({
            at,
            costUSD: Number.isFinite(call.costUSD) && call.costUSD > 0 ? call.costUSD : 0,
            tokens: {
              input: call.usage.inputTokens,
              output: call.usage.outputTokens,
              cacheRead: call.usage.cacheReadInputTokens,
              cacheWrite: call.usage.cacheCreationInputTokens,
            },
            model: call.model,
            unpriced: isUnpriced(call.model, call.costUSD),
            chatId,
            chatTitle,
          })
        }
      }
    }
  }
  return out
}
