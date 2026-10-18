// The host side of the Claude sessions view across paired devices: fetch
// each device's Claude spend slots and limit hits, keep them in a local
// cache so a device that is off still counts, and hand them to the limits
// math. `codeburn limits --devices` fetches; plain `codeburn limits` only
// reads the cache and makes no network calls.

import { mkdir, readFile, readdir, unlink } from 'fs/promises'
import { join } from 'path'

import { getCodeburnCacheDir } from '../cache-dir.js'
import { writeFileAtomic } from '../claude-limit-sources.js'
import type { DeviceStatus, LimitEvent, LimitSlot, PeerLimitData } from '../claude-limits.js'
import { fetchClaudeLimits } from './client.js'
import { CLAUDE_LIMITS_SHARE_VERSION } from './claude-limits-share.js'
import { loadOrCreateIdentity } from './identity.js'
import { getSharingDir, loadRemotes, type RemoteDevice } from './store.js'

export const PEER_CACHE_DIR = 'claude-limit-peers'
const CACHE_VERSION = 1
const SLOT_MS = 10 * 60 * 1000
/// A device that answered is asked again after this long; one that did not,
/// after the longer wait, so an offline device does not slow every refresh.
const MIN_FETCH_INTERVAL_MS = 30 * 1000
const FAILED_FETCH_BACKOFF_MS = 2 * 60 * 1000

type PeerCache = {
  version: number
  id: string
  name: string
  status: DeviceStatus
  lastAttemptAt: number | null
  lastSyncedAt: number | null
  through: number | null
  lastCallAt: number | null
  accountHash: string | null
  slots: LimitSlot[]
  events: LimitEvent[]
}

function cachePath(cacheDir: string, fingerprint: string): string {
  return join(cacheDir, PEER_CACHE_DIR, `${fingerprint.replace(/[^a-f0-9]/gi, '')}.json`)
}

function emptyCache(remote: RemoteDevice): PeerCache {
  return {
    version: CACHE_VERSION,
    id: remote.fingerprint,
    name: remote.name,
    status: 'not_synced',
    lastAttemptAt: null,
    lastSyncedAt: null,
    through: null,
    lastCallAt: null,
    accountHash: null,
    slots: [],
    events: [],
  }
}

async function readCache(cacheDir: string, remote: RemoteDevice): Promise<PeerCache> {
  try {
    const parsed = JSON.parse(await readFile(cachePath(cacheDir, remote.fingerprint), 'utf-8')) as PeerCache
    if (parsed?.version === CACHE_VERSION && parsed.id === remote.fingerprint && Array.isArray(parsed.slots) && Array.isArray(parsed.events)) {
      return { ...parsed, name: remote.name }
    }
  } catch {}
  return emptyCache(remote)
}

async function writeCache(cacheDir: string, cache: PeerCache): Promise<void> {
  await mkdir(join(cacheDir, PEER_CACHE_DIR), { recursive: true, mode: 0o700 })
  await writeFileAtomic(cachePath(cacheDir, cache.id), JSON.stringify(cache))
}

function num(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

function time(value: unknown): number | undefined {
  if (typeof value !== 'string') return undefined
  const ms = Date.parse(value)
  return Number.isFinite(ms) ? ms : undefined
}

/// A device's answer, checked field by field: anything malformed is dropped,
/// never trusted.
export function parseShareAnswer(json: unknown): {
  through: number
  lastCallAt: number | null
  accountHash: string | null
  slots: LimitSlot[]
  events: LimitEvent[]
} | null {
  if (!json || typeof json !== 'object') return null
  const r = json as Record<string, unknown>
  if (r['version'] !== CLAUDE_LIMITS_SHARE_VERSION) return null
  const through = time(r['through'])
  if (through === undefined) return null
  const slots: LimitSlot[] = []
  for (const raw of Array.isArray(r['slots']) ? r['slots'] : []) {
    if (!raw || typeof raw !== 'object') continue
    const s = raw as Record<string, unknown>
    const at = time(s['at'])
    const firstAt = time(s['firstAt'])
    const lastAt = time(s['lastAt'])
    const costUSD = num(s['costUSD'])
    const model = typeof s['model'] === 'string' ? s['model'].slice(0, 120) : undefined
    const t = s['tokens'] && typeof s['tokens'] === 'object' ? s['tokens'] as Record<string, unknown> : {}
    if (at === undefined || firstAt === undefined || lastAt === undefined || costUSD === undefined || costUSD < 0 || !model) continue
    slots.push({
      at,
      firstAt,
      lastAt,
      model,
      ...(typeof s['modelName'] === 'string' ? { modelName: s['modelName'].slice(0, 80) } : {}),
      costUSD,
      unpriced: s['unpriced'] === true,
      tokens: {
        input: Math.max(0, num(t['input']) ?? 0),
        output: Math.max(0, num(t['output']) ?? 0),
        cacheRead: Math.max(0, num(t['cacheRead']) ?? 0),
        cacheWrite: Math.max(0, num(t['cacheWrite']) ?? 0),
      },
    })
  }
  const events: LimitEvent[] = []
  for (const raw of Array.isArray(r['events']) ? r['events'] : []) {
    if (!raw || typeof raw !== 'object') continue
    const e = raw as Record<string, unknown>
    const at = time(e['at'])
    const resetsAt = time(e['resetsAt'])
    const limit = e['limit']
    if (at === undefined || resetsAt === undefined || (limit !== 'five_hour' && limit !== 'seven_day')) continue
    events.push({ limit, at, resetsAt })
  }
  return {
    through,
    lastCallAt: time(r['lastCallAt']) ?? null,
    accountHash: typeof r['accountHash'] === 'string' && r['accountHash'] ? r['accountHash'] : null,
    slots,
    events,
  }
}

/// A fresh answer replaces the cached slots from its own start; older ones
/// stay. Everything older than the lookback goes.
export function mergeShareAnswer(cache: PeerCache, since: number | null, answer: NonNullable<ReturnType<typeof parseShareAnswer>>, floor: number): PeerCache {
  const replacedFrom = since === null ? Number.NEGATIVE_INFINITY : Math.floor(since / SLOT_MS) * SLOT_MS
  const slots = [
    ...cache.slots.filter(s => s.at < replacedFrom && s.at >= floor),
    ...answer.slots.filter(s => s.at >= replacedFrom && s.at >= floor),
  ].sort((a, b) => a.at - b.at || a.model.localeCompare(b.model))
  const seen = new Set<string>()
  const events = [...cache.events, ...answer.events]
    .filter(e => e.at >= floor)
    .filter(e => {
      const key = `${e.limit}|${e.at}|${e.resetsAt}`
      if (seen.has(key)) return false
      seen.add(key)
      return true
    })
    .sort((a, b) => a.at - b.at)
  return {
    ...cache,
    through: answer.through,
    lastCallAt: answer.lastCallAt ?? cache.lastCallAt,
    accountHash: answer.accountHash,
    slots,
    events,
  }
}

export type RefreshOptions = {
  now?: number
  lookbackMs: number
  /// This device's account hash; a device with a different one is not counted.
  ownAccountHash: string | null
  sharingDir?: string
  cacheDir?: string
}

/// Ask every paired device for what changed since its cached data, in
/// parallel, and update the caches. Never throws: a device that fails keeps
/// its cache and records why.
export async function refreshPeerCaches(opts: RefreshOptions): Promise<void> {
  const now = opts.now ?? Date.now()
  const sharingDir = opts.sharingDir ?? getSharingDir()
  const cacheDir = opts.cacheDir ?? getCodeburnCacheDir()
  const remotes = await loadRemotes(sharingDir)
  await removeOrphanCaches(cacheDir, remotes)
  if (remotes.length === 0) return
  const identity = await loadOrCreateIdentity(sharingDir)
  const floor = now - opts.lookbackMs
  await Promise.all(remotes.map(async remote => {
    const cache = await readCache(cacheDir, remote)
    const wait = cache.status === 'ok' ? MIN_FETCH_INTERVAL_MS : FAILED_FETCH_BACKOFF_MS
    if (cache.lastAttemptAt !== null && now - cache.lastAttemptAt < wait && now >= cache.lastAttemptAt) return
    // The last slot of the previous answer may have been partial.
    const since = cache.through === null ? null : Math.max(floor, cache.through - SLOT_MS)
    let next: PeerCache = { ...cache, lastAttemptAt: now }
    try {
      const res = await fetchClaudeLimits(
        { identity, host: remote.host, port: remote.port, expectedFingerprint: remote.fingerprint },
        remote.token,
        since === null ? undefined : new Date(since).toISOString(),
      )
      if (res.status === 200) {
        const answer = parseShareAnswer(res.json)
        if (!answer) {
          next.status = 'unsupported'
        } else if (answer.accountHash && opts.ownAccountHash && answer.accountHash !== opts.ownAccountHash) {
          next = { ...next, status: 'other_account', accountHash: answer.accountHash, slots: [], events: [], through: answer.through, lastSyncedAt: now }
        } else {
          next = { ...mergeShareAnswer(next, since, answer, floor), status: 'ok', lastSyncedAt: now }
        }
      } else if (res.status === 404) {
        next.status = 'unsupported'
      } else if (res.status === 401) {
        next.status = 'unauthorized'
      } else {
        next.status = 'unreachable'
      }
    } catch {
      next.status = 'unreachable'
    }
    try {
      await writeCache(cacheDir, next)
    } catch {}
  }))
}

/// Caches of devices no longer paired, from any removal path.
async function removeOrphanCaches(cacheDir: string, remotes: RemoteDevice[]): Promise<void> {
  const keep = new Set(remotes.map(r => `${r.fingerprint.replace(/[^a-f0-9]/gi, '')}.json`))
  let names: string[]
  try {
    names = await readdir(join(cacheDir, PEER_CACHE_DIR))
  } catch {
    return
  }
  await Promise.all(names.filter(n => n.endsWith('.json') && !keep.has(n)).map(n => unlink(join(cacheDir, PEER_CACHE_DIR, n)).catch(() => {})))
}

/// Every paired device's cached data for the limits math. No network.
export async function readPeerLimitData(opts: { sharingDir?: string; cacheDir?: string } = {}): Promise<PeerLimitData[]> {
  const sharingDir = opts.sharingDir ?? getSharingDir()
  const cacheDir = opts.cacheDir ?? getCodeburnCacheDir()
  const remotes = await loadRemotes(sharingDir)
  return Promise.all(remotes.map(async (remote): Promise<PeerLimitData> => {
    const cache = await readCache(cacheDir, remote)
    return {
      id: remote.fingerprint,
      name: remote.name,
      addedAt: remote.addedAt,
      status: cache.status,
      through: cache.through,
      lastCallAt: cache.lastCallAt,
      lastSyncedAt: cache.lastSyncedAt,
      slots: cache.slots,
      events: cache.events,
    }
  }))
}
