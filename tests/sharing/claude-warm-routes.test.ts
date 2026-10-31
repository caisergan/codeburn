import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest'

import { generateIdentity, type Identity } from '../../src/sharing/identity.js'
import { PeerStore } from '../../src/sharing/pairing.js'
import { ShareServer } from '../../src/sharing/share-server.js'
import { fetchWarmStatus, pair, postWarmNow, putWarmSchedule } from '../../src/sharing/client.js'

describe('Claude warm routes on the share server', () => {
  let serverId: Identity
  let clientId: Identity
  const servers: ShareServer[] = []

  beforeAll(async () => {
    serverId = await generateIdentity('VM')
    clientId = await generateIdentity('Mac')
  })
  afterAll(async () => {
    await Promise.all(servers.map(s => s.close()))
  })

  async function start(warm?: ConstructorParameters<typeof ShareServer>[0]['warm']) {
    const server = new ShareServer({ identity: serverId, peers: new PeerStore(), getUsage: async () => ({}), warm })
    servers.push(server)
    const port = await server.listen(0, '127.0.0.1')
    const ep = { identity: clientId, host: '127.0.0.1', port, expectedFingerprint: serverId.fingerprint }
    const pr = await pair(ep, server.openPairing(), 'Mac')
    return { ep, token: (pr.json as { token: string }).token }
  }

  const handlers = (allowed: boolean) => ({
    allowed,
    status: vi.fn(async () => ({ allowed, history: [] })),
    setSchedule: vi.fn(async (body: unknown) => ((body as { times?: unknown })?.times ? { ok: true } : null)),
    warmNow: vi.fn(async () => ({ outcome: 'started' })),
  })

  it('answers 404 on a build without the warmer', async () => {
    const { ep, token } = await start()
    expect((await fetchWarmStatus(ep, token)).status).toBe(404)
  })

  it('requires the paired token', async () => {
    const { ep } = await start(handlers(true))
    expect((await fetchWarmStatus(ep, 'wrong')).status).toBe(401)
    expect((await postWarmNow(ep, 'wrong')).status).toBe(401)
  })

  it('without --allow-warm: status readable, schedule and warm refused', async () => {
    const h = handlers(false)
    const { ep, token } = await start(h)
    const status = await fetchWarmStatus(ep, token)
    expect(status.status).toBe(200)
    expect(status.json).toMatchObject({ allowed: false })
    expect((await putWarmSchedule(ep, token, { times: ['07:00'] })).status).toBe(403)
    expect((await postWarmNow(ep, token)).status).toBe(403)
    expect(h.warmNow).not.toHaveBeenCalled()
    expect(h.setSchedule).not.toHaveBeenCalled()
  })

  it('with --allow-warm: stores a schedule, rejects a bad one, warms on request', async () => {
    const h = handlers(true)
    const { ep, token } = await start(h)
    expect((await putWarmSchedule(ep, token, { times: ['07:00'] })).status).toBe(200)
    expect((await putWarmSchedule(ep, token, { nope: true })).status).toBe(400)
    const now = await postWarmNow(ep, token)
    expect(now.status).toBe(200)
    expect(now.json).toEqual({ outcome: 'started' })
    expect(h.warmNow).toHaveBeenCalledTimes(1)
  })
})
