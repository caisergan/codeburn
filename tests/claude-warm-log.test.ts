import { mkdtemp, readFile, rm, writeFile } from 'fs/promises'
import { tmpdir } from 'os'
import { join } from 'path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { describeResult } from '../src/claude-warm-cli.js'
import {
  createWarmLogger,
  formatWarmLogLine,
  readWarmLog,
  WARM_LOG_MAX_BYTES,
  warmLogPathFor,
} from '../src/claude-warm-log.js'
import {
  hasStoredLogin,
  performWarm,
  readingOf,
  runWarm,
  setWarmSchedule,
  startWarmScheduler,
  type FiveHourReading,
  type SendResult,
  type WarmResult,
} from '../src/claude-warm.js'
import type { ClaudeResult } from '../src/quota/claude.js'
import type { QuotaProvider } from '../src/quota/types.js'

const quota = (connection: QuotaProvider['connection'], over: Partial<QuotaProvider> = {}): QuotaProvider => ({
  provider: 'claude',
  connection,
  primary: null,
  details: [],
  planLabel: null,
  footerLines: [],
  ...over,
})

describe('why usage could not be read', () => {
  const at = Date.parse('2026-11-03T10:00:00Z')
  const read = (res: ClaudeResult): FiveHourReading => readingOf(res, at)

  it('names a missing or wiped login as signed out, with the fix', () => {
    expect(read({ quota: quota('disconnected') })).toMatchObject({
      state: 'unknown',
      problem: 'signed_out',
      detail: expect.stringContaining('/login'),
    })
  })

  it('tells an expired login from a refused request', () => {
    expect(read({ quota: quota('terminalFailure', { footerLines: ['Claude Code login expired.'] }), httpStatus: 401 }))
      .toMatchObject({ problem: 'login_expired' })
    expect(read({ quota: quota('terminalFailure'), httpStatus: 403 }))
      .toMatchObject({ problem: 'rejected', detail: expect.stringContaining('HTTP 403') })
  })

  it('reports rate limits, server errors and network errors with their numbers', () => {
    expect(read({ quota: quota('transientFailure'), retryAfterSeconds: 300, httpStatus: 429 }))
      .toMatchObject({ problem: 'rate_limited', detail: expect.stringContaining('300s') })
    expect(read({ quota: quota('transientFailure'), httpStatus: 503 }))
      .toMatchObject({ problem: 'unreachable', detail: expect.stringContaining('HTTP 503') })
    expect(read({ quota: quota('transientFailure'), error: 'fetch failed' }))
      .toMatchObject({ problem: 'unreachable', detail: expect.stringContaining('fetch failed') })
    expect(read({ quota: quota('accessDenied') })).toMatchObject({ problem: 'access_denied' })
  })

  it('flags an answer without a 5-hour window, and still reads a good one', () => {
    expect(read({ quota: quota('connected') })).toMatchObject({ problem: 'no_five_hour' })
    expect(read({ quota: quota('connected', { details: [{ label: '5-hour', percent: 0.2, resetsAt: '2026-11-03T12:00:00.000Z' }] }) }))
      .toEqual({ state: 'running', resetsAt: '2026-11-03T12:00:00.000Z', percent: 0.2 })
  })
})

describe('performWarm with an unreadable usage', () => {
  const base = { sleep: async () => {}, now: () => new Date('2026-11-03T10:00:00Z') }

  it('skips as signed_out when Claude Code has no login, keeping the cause', async () => {
    const send = vi.fn<() => Promise<SendResult>>()
    const res = await performWarm({ trigger: 'manual' }, {
      ...base,
      send,
      readFiveHour: async () => ({ state: 'unknown', problem: 'signed_out', detail: 'Claude Code is not signed in on this machine' }),
    })
    expect(send).not.toHaveBeenCalled()
    expect(res).toMatchObject({ outcome: 'skipped', reason: 'signed_out', detail: 'Claude Code is not signed in on this machine' })
  })

  it('keeps the cause of any other failed read in the result', async () => {
    const res = await performWarm({ trigger: 'manual' }, {
      ...base,
      send: vi.fn(),
      readFiveHour: async () => ({ state: 'unknown', problem: 'unreachable', detail: 'the usage endpoint answered HTTP 503' }),
    })
    expect(res).toMatchObject({ reason: 'usage_unavailable', detail: 'the usage endpoint answered HTTP 503' })
  })

  it('records a thrown reading as its message', async () => {
    const res = await performWarm({ trigger: 'manual' }, { ...base, send: vi.fn(), readFiveHour: async () => { throw new Error('boom') } })
    expect(res).toMatchObject({ reason: 'usage_unavailable', detail: 'boom' })
  })

  it('says so in the CLI', () => {
    const result: WarmResult = { at: '', trigger: 'manual', outcome: 'skipped', reason: 'signed_out', detail: 'Claude Code is not signed in on this machine', resetsAt: null, slot: null }
    expect(describeResult(result)).toBe('Skipped: Claude Code is not signed in on this machine.')
    expect(describeResult({ ...result, reason: 'usage_unavailable', detail: 'HTTP 503' })).toContain('(HTTP 503)')
  })
})

describe('files', () => {
  let dir: string
  let statePath: string
  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), 'codeburn-warm-log-'))
    statePath = join(dir, 'claude-warm.json')
  })
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true })
  })

  it('treats a credentials file with empty tokens as signed out', async () => {
    const file = join(dir, '.credentials.json')
    expect(await hasStoredLogin(file)).toBe(false)
    await writeFile(file, JSON.stringify({ claudeAiOauth: { accessToken: '', refreshToken: '', expiresAt: 0 } }))
    expect(await hasStoredLogin(file)).toBe(false)
    await writeFile(file, JSON.stringify({ claudeAiOauth: { accessToken: '', refreshToken: 'r', expiresAt: 0 } }))
    expect(await hasStoredLogin(file)).toBe(true)
    await writeFile(file, 'not json')
    expect(await hasStoredLogin(file)).toBe(false)
  })

  it('formats lines with quoted values only where needed', () => {
    expect(formatWarmLogLine(new Date('2026-11-03T10:00:00Z'), 'warn', 'warm.skipped', { reason: 'signed_out', detail: 'not signed in', gone: undefined }))
      .toBe('2026-11-03T10:00:00.000Z WARN  warm.skipped reason=signed_out detail="not signed in"\n')
  })

  it('logs each warm with its cause next to the state file', async () => {
    await runWarm({ trigger: 'manual' }, {
      send: vi.fn(),
      sleep: async () => {},
      readFiveHour: async () => ({ state: 'unknown', problem: 'signed_out', detail: 'Claude Code is not signed in on this machine' }),
    }, statePath)
    const lines = await readWarmLog(warmLogPathFor(statePath), 10)
    expect(lines).toHaveLength(2)
    expect(lines[0]).toContain('INFO  warm.begin trigger=manual')
    expect(lines[1]).toContain('WARN  warm.skipped trigger=manual reason=signed_out detail="Claude Code is not signed in on this machine"')
  })

  it('rotates past the size cap and reads across the rotation', async () => {
    const path = warmLogPathFor(statePath)
    await writeFile(path, `${'x'.repeat(WARM_LOG_MAX_BYTES)}\nold\n`)
    await createWarmLogger(path)('info', 'fresh')
    expect(await readFile(path, 'utf8')).toMatch(/INFO {2}fresh\n$/)
    expect((await readFile(`${path}.1`, 'utf8')).endsWith('old\n')).toBe(true)
    const tail = await readWarmLog(path, 2)
    expect(tail[0]).toBe('old')
    expect(tail[1]).toContain('fresh')
  })

  it('logs an auto-warm poll problem once, and again when it clears', async () => {
    await setWarmSchedule({ enabled: false, times: [], days: [0, 1, 2, 3, 4, 5, 6], timeZone: 'UTC', auto: { enabled: true, from: '07:00', to: '24:00' } }, statePath)
    let reading: FiveHourReading = { state: 'unknown', problem: 'signed_out', detail: 'not signed in' }
    let now = new Date('2026-11-03T03:00:00Z')
    const scheduler = startWarmScheduler({ statePath, now: () => now, intervalMs: 60 * 60_000, pollMs: 60_000, read: async () => reading, warm: vi.fn(async () => {}) })
    try {
      await scheduler.tick()
      now = new Date(now.getTime() + 2 * 60_000)
      await scheduler.tick()
      reading = { state: 'idle' }
      now = new Date(now.getTime() + 2 * 60_000)
      await scheduler.tick()
    } finally {
      scheduler.stop()
    }
    const lines = await readWarmLog(warmLogPathFor(statePath), 10)
    expect(lines.filter(l => l.includes('usage.unreadable'))).toHaveLength(1)
    expect(lines[0]).toContain('problem=signed_out')
    expect(lines[lines.length - 1]).toContain('usage.readable state=idle')
  })
})
