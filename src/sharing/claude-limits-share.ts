// What a paired device sends for the Claude 5-hour sessions and weeks: its
// Claude spend in 10-minute slots per model, the refused requests in its
// transcripts, and a hash of the signed-in account. No chat, project, path or
// prompt leaves the device. See docs/design/claude-session-usage.md, "Paired
// devices".

import { aggregateLimitSlots, collectLimitCalls, collectLimitEvents, readClaudeAccountHash } from '../claude-limit-sources.js'
import { LOOKBACK_MS } from '../claude-limits-report.js'
import type { LimitEvent, LimitSlot } from '../claude-limits.js'
import { parseAllSessions } from '../parser.js'
import { getClaudeConfigDirs } from '../providers/claude.js'

export const CLAUDE_LIMITS_SHARE_VERSION = 1
const SLOT_MS = 10 * 60 * 1000

export type ClaudeLimitsShare = {
  version: number
  /// The time this answer's parse covers, and the device's newest call.
  through: string
  lastCallAt: string | null
  accountHash: string | null
  slots: Array<Omit<LimitSlot, 'at' | 'firstAt' | 'lastAt'> & { at: string; firstAt: string; lastAt: string }>
  events: Array<Omit<LimitEvent, 'at' | 'resetsAt'> & { at: string; resetsAt: string }>
}

const iso = (ms: number): string => new Date(ms).toISOString()

/// Slots and refused requests since `sinceMs`, at most the limits lookback.
export async function buildClaudeLimitsShare(sinceMs: number | undefined, now = Date.now()): Promise<ClaudeLimitsShare> {
  const floor = now - LOOKBACK_MS
  const asked = sinceMs !== undefined && Number.isFinite(sinceMs) ? Math.min(Math.max(sinceMs, floor), now) : floor
  // From the start of the slot `since` falls in: the host replaces its cache
  // from there, so that slot has to come back whole.
  const since = Math.floor(asked / SLOT_MS) * SLOT_MS
  // Whole local days, like `codeburn limits`, so the parse memo is shared.
  const from = new Date(since)
  const start = new Date(from.getFullYear(), from.getMonth(), from.getDate())
  const today = new Date(now)
  const end = new Date(today.getFullYear(), today.getMonth(), today.getDate(), 23, 59, 59, 999)
  const dirs = await getClaudeConfigDirs()
  const defaultDir = dirs[0]
  const [projects, events, accountHash] = await Promise.all([
    parseAllSessions({ start, end }, 'claude'),
    defaultDir ? collectLimitEvents([defaultDir], since) : Promise.resolve([] as LimitEvent[]),
    readClaudeAccountHash(defaultDir),
  ])
  const calls = collectLimitCalls(projects, dirs.length > 1 ? defaultDir : undefined)
  const recent = calls.filter(c => c.at >= since && c.at <= now)
  const lastCallAt = recent.reduce<number | null>((max, c) => (max === null || c.at > max ? c.at : max), null)
  return {
    version: CLAUDE_LIMITS_SHARE_VERSION,
    through: iso(now),
    lastCallAt: lastCallAt === null ? null : iso(lastCallAt),
    accountHash,
    slots: aggregateLimitSlots(recent).map(slot => ({ ...slot, at: iso(slot.at), firstAt: iso(slot.firstAt), lastAt: iso(slot.lastAt) })),
    events: events.filter(e => e.at >= since).map(e => ({ limit: e.limit, at: iso(e.at), resetsAt: iso(e.resetsAt) })),
  }
}
