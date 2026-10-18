import { mkdtemp, readdir, rm, writeFile, mkdir } from 'fs/promises'
import { tmpdir } from 'os'
import { join } from 'path'

import { afterAll, beforeAll, describe, expect, it } from 'vitest'

import { fetchClaudeLimits, pair } from '../../src/sharing/client.js'
import { mergeShareAnswer, parseShareAnswer, PEER_CACHE_DIR, readPeerLimitData, refreshPeerCaches } from '../../src/sharing/claude-limit-peers.js'
import { CLAUDE_LIMITS_SHARE_VERSION } from '../../src/sharing/claude-limits-share.js'
import { generateIdentity, loadOrCreateIdentity, type Identity } from '../../src/sharing/identity.js'
import { PeerStore } from '../../src/sharing/pairing.js'
import { ShareServer } from '../../src/sharing/share-server.js'
import { saveRemotes, type RemoteDevice } from '../../src/sharing/store.js'

const t = (s: string): number => Date.parse(s)
const NOW = t('2026-10-15T07:00:00Z')
const LOOKBACK = 36 * 24 * 60 * 60 * 1000

function answer(opts: { through?: string; accountHash?: string | null; slots?: Array<[string, number]> } = {}) {
  return {
    version: CLAUDE_LIMITS_SHARE_VERSION,
    through: opts.through ?? '2026-10-15T06:59:00.000Z',
    lastCallAt: '2026-10-15T06:40:00.000Z',
    accountHash: opts.accountHash === undefined ? 'acct-1' : opts.accountHash,
    slots: (opts.slots ?? [['2026-10-15T06:40:00.000Z', 4]]).map(([at, costUSD]) => ({
      at,
      firstAt: at,
      lastAt: at,
      model: 'claude-opus-5-5',
      modelName: 'Opus 5.5',
      costUSD,
      unpriced: false,
      tokens: { input: 1, output: 2, cacheRead: 3, cacheWrite: 4 },
    })),
    events: [{ limit: 'five_hour', at: '2026-10-15T06:45:00.000Z', resetsAt: '2026-10-15T07:00:00.000Z' }],
  }
}

describe('Claude limits across paired devices (loopback mutual TLS)', () => {
  let root: string
  let sharingDir: string
  let cacheDir: string
  let serverId: Identity
  let clientId: Identity
  let server: ShareServer
  let oldServer: ShareServer
  let port: number
  let oldPort: number
  let token: string
  let oldToken: string
  const asked: Array<string | undefined> = []
  let next: unknown = answer()

  beforeAll(async () => {
    root = await mkdtemp(join(tmpdir(), 'codeburn-peers-'))
    sharingDir = join(root, 'sharing')
    cacheDir = join(root, 'cache')
    clientId = await loadOrCreateIdentity(sharingDir, 'Mac')
    serverId = await generateIdentity('instance-vm')
    server = new ShareServer({
      identity: serverId,
      peers: new PeerStore(),
      getUsage: async () => ({}),
      getClaudeLimits: async (since) => {
        asked.push(since === undefined ? undefined : new Date(since).toISOString())
        return next
      },
    })
    port = await server.listen(0, '127.0.0.1')
    // A peer built before the endpoint existed.
    oldServer = new ShareServer({ identity: await generateIdentity('old-mac'), peers: new PeerStore(), getUsage: async () => ({}) })
    oldPort = await oldServer.listen(0, '127.0.0.1')

    const ep = { identity: clientId, host: '127.0.0.1', port }
    token = ((await pair(ep, server.openPairing(), 'Mac')).json as { token: string }).token
    oldToken = ((await pair({ ...ep, port: oldPort }, oldServer.openPairing(), 'Mac')).json as { token: string }).token
  })

  afterAll(async () => {
    await server.close()
    await oldServer.close()
    await rm(root, { recursive: true, force: true })
  })

  const remote = (): RemoteDevice => ({ name: 'instance-vm', host: '127.0.0.1', port, fingerprint: serverId.fingerprint, token, addedAt: t('2026-10-01T00:00:00Z') })
  const refresh = (now: number, own: string | null = 'acct-1') =>
    refreshPeerCaches({ now, lookbackMs: LOOKBACK, ownAccountHash: own, sharingDir, cacheDir })

  it('denies the endpoint without a paired token', async () => {
    const r = await fetchClaudeLimits({ identity: clientId, host: '127.0.0.1', port }, 'nope', undefined)
    expect(r.status).toBe(401)
  })

  it('fetches the whole lookback first, then only what changed', async () => {
    await saveRemotes([remote()], sharingDir)
    asked.length = 0
    next = answer({ slots: [['2026-10-15T06:40:00.000Z', 4], ['2026-10-14T10:00:00.000Z', 2]] })
    await refresh(NOW)
    // No `since`: the device answers its own lookback.
    expect(asked).toEqual([undefined])

    let [peer] = await readPeerLimitData({ sharingDir, cacheDir })
    expect(peer).toMatchObject({ id: serverId.fingerprint, name: 'instance-vm', status: 'ok', through: t('2026-10-15T06:59:00Z'), lastSyncedAt: NOW })
    expect(peer!.slots.map(s => s.costUSD)).toEqual([2, 4])
    expect(peer!.events).toHaveLength(1)

    // Within 30 s of a good fetch nothing is asked.
    await refresh(NOW + 10_000)
    expect(asked).toHaveLength(1)

    // Later: from the cached `through` minus one slot; the overlap is replaced.
    next = answer({ through: '2026-10-15T07:05:00.000Z', slots: [['2026-10-15T06:40:00.000Z', 6], ['2026-10-15T07:00:00.000Z', 1]] })
    await refresh(NOW + 60_000)
    expect(asked[1]).toBe('2026-10-15T06:49:00.000Z')
    ;[peer] = await readPeerLimitData({ sharingDir, cacheDir })
    // The overlap starts at the 06:40 slot, which the device sends whole
    // again; it replaces the cached copy, and older slots stay.
    expect(peer!.slots.map(s => [new Date(s.at).toISOString(), s.costUSD])).toEqual([
      ['2026-10-14T10:00:00.000Z', 2],
      ['2026-10-15T06:40:00.000Z', 6],
      ['2026-10-15T07:00:00.000Z', 1],
    ])
    expect(peer!.events).toHaveLength(1)
  })

  it('keeps the cache and records the failure when a device is unreachable', async () => {
    await saveRemotes([{ ...remote(), port: 9 }], sharingDir)
    await refresh(NOW + 5 * 60_000)
    const [peer] = await readPeerLimitData({ sharingDir, cacheDir })
    expect(peer!.status).toBe('unreachable')
    expect(peer!.slots.length).toBeGreaterThan(0)
  })

  it('drops a device on another Claude account', async () => {
    await saveRemotes([remote()], sharingDir)
    next = answer({ accountHash: 'acct-2' })
    await refresh(NOW + 20 * 60_000)
    const [peer] = await readPeerLimitData({ sharingDir, cacheDir })
    expect(peer!.status).toBe('other_account')
    expect(peer!.slots).toEqual([])
    expect(peer!.events).toEqual([])
  })

  it('reads a 404 as an older CodeBurn', async () => {
    const old: RemoteDevice = { name: 'old-mac', host: '127.0.0.1', port: oldPort, fingerprint: 'abc123', token: oldToken, addedAt: NOW }
    // The pinned fingerprint must match the old server's certificate.
    const oldHello = await fetchClaudeLimits({ identity: clientId, host: '127.0.0.1', port: oldPort }, oldToken, undefined)
    old.fingerprint = oldHello.serverFingerprint
    await saveRemotes([old], sharingDir)
    await refresh(NOW + 40 * 60_000)
    const [peer] = await readPeerLimitData({ sharingDir, cacheDir })
    expect(peer!.status).toBe('unsupported')
  })

  it('removes the caches of devices that are no longer paired', async () => {
    await mkdir(join(cacheDir, PEER_CACHE_DIR), { recursive: true })
    await writeFile(join(cacheDir, PEER_CACHE_DIR, 'deadbeef.json'), '{}')
    await saveRemotes([], sharingDir)
    await refresh(NOW + 60 * 60_000)
    expect(await readdir(join(cacheDir, PEER_CACHE_DIR))).toEqual([])
    expect(await readPeerLimitData({ sharingDir, cacheDir })).toEqual([])
  })
})

describe('a device’s answer', () => {
  it('is checked field by field', () => {
    const parsed = parseShareAnswer({
      ...answer(),
      slots: [
        ...answer().slots,
        { at: 'nope', firstAt: 'x', lastAt: 'x', model: 'm', costUSD: 1 },
        { ...answer().slots[0], costUSD: -5 },
        { ...answer().slots[0], model: '' },
      ],
      events: [...answer().events, { limit: 'monthly', at: '2026-10-15T06:45:00.000Z', resetsAt: '2026-10-15T07:00:00.000Z' }],
    })
    expect(parsed!.slots).toHaveLength(1)
    expect(parsed!.events).toHaveLength(1)
    expect(parseShareAnswer({ ...answer(), version: 2 })).toBeNull()
    expect(parseShareAnswer(null)).toBeNull()
  })

  it('replaces the cache from its own start and prunes the lookback', () => {
    const cache = {
      version: 1, id: 'fp', name: 'vm', status: 'ok' as const, lastAttemptAt: null, lastSyncedAt: null,
      through: null, lastCallAt: null, accountHash: null,
      slots: parseShareAnswer(answer({ slots: [['2026-09-01T00:00:00.000Z', 9], ['2026-10-15T06:00:00.000Z', 1], ['2026-10-15T06:40:00.000Z', 2]] }))!.slots,
      events: [],
    }
    const merged = mergeShareAnswer(cache, t('2026-10-15T06:35:00Z'), parseShareAnswer(answer({ slots: [['2026-10-15T06:40:00.000Z', 5]] }))!, t('2026-09-10T00:00:00Z'))
    expect(merged.slots.map(s => s.costUSD)).toEqual([1, 5])
  })
})
