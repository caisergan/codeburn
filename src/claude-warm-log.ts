// The window warmer's log: one line per decision, so a warm that did nothing
// can be traced to its cause (signed out, usage endpoint down, Claude Code's
// own error) on the machine that ran it. `codeburn warm log` prints it.
//
// Lines look like
//   2026-11-03T10:55:44.265Z WARN  warm.skipped trigger=manual reason=signed_out detail="…"
// Values are never tokens: details come from sanitized errors and Claude
// Code's last output line.

import { appendFile, mkdir, readFile, rename, stat } from 'fs/promises'
import { dirname, join } from 'path'

export type WarmLogLevel = 'info' | 'warn' | 'error'
export type WarmLogFields = Record<string, string | number | boolean | null | undefined>
export type WarmLogger = (level: WarmLogLevel, event: string, fields?: WarmLogFields) => Promise<void>

/// The log is rotated to `<name>.1` past this size, so it stays under ~1 MB.
export const WARM_LOG_MAX_BYTES = 512 * 1024

/// Next to the state file, so tests that use a temporary state get a temporary log.
export function warmLogPathFor(statePath: string): string {
  return join(dirname(statePath), 'claude-warm.log')
}

function formatValue(value: string | number | boolean | null): string {
  if (typeof value !== 'string') return String(value)
  return /^[\w.:/@+-]+$/.test(value) ? value : JSON.stringify(value)
}

export function formatWarmLogLine(at: Date, level: WarmLogLevel, event: string, fields: WarmLogFields = {}): string {
  const parts = [at.toISOString(), level.toUpperCase().padEnd(5), event]
  for (const [key, value] of Object.entries(fields)) {
    if (value === undefined) continue
    parts.push(`${key}=${formatValue(value)}`)
  }
  return `${parts.join(' ')}\n`
}

/// Writes are chained per path so lines keep their order within a process.
const queues = new Map<string, Promise<void>>()

/// A logger that appends to `path`. It never throws: a log that cannot be
/// written must not stop a warm.
export function createWarmLogger(path: string, now: () => Date = () => new Date()): WarmLogger {
  return (level, event, fields) => {
    const line = formatWarmLogLine(now(), level, event, fields)
    const previous = queues.get(path) ?? Promise.resolve()
    const next = previous.then(async () => {
      try {
        await mkdir(dirname(path), { recursive: true, mode: 0o700 })
        const size = await stat(path).then(s => s.size, () => 0)
        if (size >= WARM_LOG_MAX_BYTES) await rename(path, `${path}.1`).catch(() => {})
        await appendFile(path, line, { mode: 0o600 })
      } catch {
        // Logging is best effort.
      }
    })
    queues.set(path, next)
    void next.finally(() => {
      if (queues.get(path) === next) queues.delete(path)
    })
    return next
  }
}

/// The last `count` lines, oldest first, reading into the rotated file when
/// the current one is shorter.
export async function readWarmLog(path: string, count: number): Promise<string[]> {
  const linesOf = async (file: string): Promise<string[]> =>
    readFile(file, 'utf8').then(text => text.split('\n').filter(Boolean), () => [])
  let lines = await linesOf(path)
  if (lines.length < count) lines = [...await linesOf(`${path}.1`), ...lines]
  return lines.slice(-count)
}
