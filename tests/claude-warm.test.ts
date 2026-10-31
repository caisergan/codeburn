import { mkdtemp, rm } from 'fs/promises'
import { tmpdir } from 'os'
import { join } from 'path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import {
  dueSlot,
  loadWarmState,
  localParts,
  parseSchedule,
  performWarm,
  runWarm,
  setWarmSchedule,
  startWarmScheduler,
  WARM_ARGS,
  type FiveHourReading,
  type SendResult,
  type WarmSchedule,
} from '../src/claude-warm.js'

const schedule = (over: Partial<WarmSchedule> = {}): WarmSchedule => ({
  enabled: true,
  times: ['07:00', '12:00'],
  days: [0, 1, 2, 3, 4, 5, 6],
  timeZone: 'Europe/Istanbul',
  ...over,
})

describe('parseSchedule', () => {
  it('snaps to 10-minute marks, de-duplicates and sorts', () => {
    expect(parseSchedule({ enabled: true, times: ['12:04', '7:00', '07:02', '23:57'], days: [4, 0, 0], timeZone: 'UTC' })).toEqual({
      enabled: true,
      times: ['07:00', '12:00', '23:50'],
      days: [0, 4],
      timeZone: 'UTC',
    })
  })

  it('rejects more than four times, bad days, bad times and unknown zones', () => {
    expect(parseSchedule({ enabled: true, times: ['01:00', '06:00', '11:00', '16:00', '21:00'], days: [], timeZone: 'UTC' })).toBeNull()
    expect(parseSchedule({ enabled: true, times: ['07:00'], days: [7], timeZone: 'UTC' })).toBeNull()
    expect(parseSchedule({ enabled: true, times: ['24:00'], days: [], timeZone: 'UTC' })).toBeNull()
    expect(parseSchedule({ enabled: true, times: ['07:00'], days: [], timeZone: 'Mars/Olympus' })).toBeNull()
    expect(parseSchedule({ times: ['07:00'], days: [], timeZone: 'UTC' })).toBeNull()
    expect(parseSchedule(null)).toBeNull()
  })
})

describe('dueSlot', () => {
  it('fires at the local time of the schedule zone, not the runner zone', () => {
    // 04:00 UTC is 07:00 in Istanbul (+03).
    expect(dueSlot(schedule(), new Date('2026-10-31T04:00:30Z'))).toEqual({ slot: '2026-10-31 07:00', time: '07:00' })
    expect(dueSlot(schedule(), new Date('2026-10-31T07:00:00Z'))).toBeNull()
  })

  it('stays due for ten minutes, then lets the slot go', () => {
    expect(dueSlot(schedule(), new Date('2026-10-31T04:09:59Z'))?.slot).toBe('2026-10-31 07:00')
    expect(dueSlot(schedule(), new Date('2026-10-31T04:10:00Z'))).toBeNull()
  })

  it('respects days (0 = Monday) and the enabled switch', () => {
    // 2026-10-31 is a Saturday (5).
    const at = new Date('2026-10-31T09:00:00Z')
    expect(dueSlot(schedule({ days: [0, 1, 2, 3, 4] }), at)).toBeNull()
    expect(dueSlot(schedule({ days: [5] }), at)?.slot).toBe('2026-10-31 12:00')
    expect(dueSlot(schedule({ enabled: false }), at)).toBeNull()
  })

  it('reads the local weekday and date across midnight', () => {
    // 22:30 UTC Saturday is 01:30 Sunday in Istanbul.
    expect(localParts(new Date('2026-10-31T22:30:00Z'), 'Europe/Istanbul')).toEqual({ ymd: '2026-11-01', weekday: 6, minutes: 90 })
  })
})

describe('performWarm', () => {
  const readings = (...list: FiveHourReading[]) => {
    const fn = vi.fn<() => Promise<FiveHourReading>>()
    for (const r of list) fn.mockResolvedValueOnce(r)
    fn.mockResolvedValue(list[list.length - 1] ?? { state: 'unknown' })
    return fn
  }
  const base = { sleep: async () => {}, now: () => new Date('2026-10-31T04:00:00Z') }

  it('sends nothing while a window runs', async () => {
    const send = vi.fn<() => Promise<SendResult>>()
    const res = await performWarm({ trigger: 'manual' }, { ...base, readFiveHour: readings({ state: 'running', resetsAt: '2026-10-31T09:00:00Z' }), send })
    expect(send).not.toHaveBeenCalled()
    expect(res).toMatchObject({ outcome: 'skipped', reason: 'window_running', resetsAt: '2026-10-31T09:00:00Z' })
  })

  it('never warms blind when usage cannot be read, and skips a used-up week', async () => {
    const send = vi.fn<() => Promise<SendResult>>()
    const unreadable = readings({ state: 'unknown' })
    expect(await performWarm({ trigger: 'scheduled' }, { ...base, readFiveHour: unreadable, send })).toMatchObject({ outcome: 'skipped', reason: 'usage_unavailable' })
    expect(unreadable).toHaveBeenCalledTimes(3)
    expect(await performWarm({ trigger: 'scheduled' }, { ...base, readFiveHour: readings({ state: 'weekly_full', resetsAt: null }), send })).toMatchObject({ outcome: 'skipped', reason: 'weekly_full' })
    expect(send).not.toHaveBeenCalled()
  })

  it('sends one message when idle and reports the new window', async () => {
    const send = vi.fn<() => Promise<SendResult>>().mockResolvedValue({ ok: true })
    const res = await performWarm(
      { trigger: 'scheduled', slot: '2026-10-31 07:00' },
      { ...base, readFiveHour: readings({ state: 'idle' }, { state: 'idle' }, { state: 'running', resetsAt: '2026-10-31T09:00:00Z' }), send },
    )
    expect(send).toHaveBeenCalledTimes(1)
    expect(res).toMatchObject({ outcome: 'started', reason: null, resetsAt: '2026-10-31T09:00:00Z', slot: '2026-10-31 07:00', trigger: 'scheduled' })
  })

  it('rides out a failed reading', async () => {
    const send = vi.fn<() => Promise<SendResult>>().mockResolvedValue({ ok: true })
    const res = await performWarm({ trigger: 'scheduled' }, { ...base, readFiveHour: readings({ state: 'unknown' }, { state: 'idle' }, { state: 'running', resetsAt: '2026-10-31T09:00:00Z' }), send })
    expect(send).toHaveBeenCalledTimes(1)
    expect(res).toMatchObject({ outcome: 'started', resetsAt: '2026-10-31T09:00:00Z' })
  })

  it('says so when Claude answered but no window shows yet', async () => {
    const send = vi.fn<() => Promise<SendResult>>().mockResolvedValue({ ok: true })
    const res = await performWarm({ trigger: 'manual' }, { ...base, readFiveHour: readings({ state: 'idle' }), send })
    expect(res).toMatchObject({ outcome: 'started', reason: 'no_window_yet' })
  })

  it('force skips the reading but still sends exactly one message', async () => {
    const read = vi.fn<() => Promise<FiveHourReading>>()
    const send = vi.fn<() => Promise<SendResult>>().mockResolvedValue({ ok: true })
    expect(await performWarm({ trigger: 'manual', force: true }, { ...base, readFiveHour: read, send })).toMatchObject({ outcome: 'started', reason: null })
    expect(read).not.toHaveBeenCalled()
    expect(send).toHaveBeenCalledTimes(1)
  })

  it('retries a network failure once on a schedule, never for a click', async () => {
    const networkFail: SendResult = { ok: false, reason: 'send_failed', detail: 'fetch failed', network: true }
    const manualSend = vi.fn<() => Promise<SendResult>>().mockResolvedValue(networkFail)
    expect(await performWarm({ trigger: 'manual' }, { ...base, readFiveHour: readings({ state: 'idle' }), send: manualSend })).toMatchObject({ outcome: 'failed', reason: 'send_failed', detail: 'fetch failed' })
    expect(manualSend).toHaveBeenCalledTimes(1)

    const scheduledSend = vi.fn<() => Promise<SendResult>>().mockResolvedValue(networkFail)
    await performWarm({ trigger: 'scheduled' }, { ...base, readFiveHour: readings({ state: 'idle' }), send: scheduledSend })
    expect(scheduledSend).toHaveBeenCalledTimes(2)
  })

  it('does not retry when the window started meanwhile', async () => {
    const send = vi.fn<() => Promise<SendResult>>().mockResolvedValue({ ok: false, reason: 'send_failed', detail: null, network: true })
    const res = await performWarm({ trigger: 'scheduled' }, { ...base, readFiveHour: readings({ state: 'idle' }, { state: 'running', resetsAt: null }), send })
    expect(send).toHaveBeenCalledTimes(1)
    expect(res).toMatchObject({ outcome: 'skipped', reason: 'window_running' })
  })
})

describe('warm message', () => {
  it('uses Claude Code with no tools, settings, MCP servers or transcript', () => {
    expect(WARM_ARGS).toEqual(expect.arrayContaining(['-p', '--model', 'haiku', '--strict-mcp-config', '--disable-slash-commands', '--no-session-persistence']))
    expect(WARM_ARGS[WARM_ARGS.indexOf('--tools') + 1]).toBe('')
    expect(WARM_ARGS[WARM_ARGS.indexOf('--setting-sources') + 1]).toBe('')
  })
})

describe('state, runWarm and the scheduler', () => {
  let dir: string
  let path: string
  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), 'codeburn-warm-test-'))
    path = join(dir, 'claude-warm.json')
  })
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true })
  })

  it('stores a valid schedule and refuses an invalid one', async () => {
    expect(await setWarmSchedule({ enabled: true, times: ['07:00'], days: [0], timeZone: 'UTC' }, path)).not.toBeNull()
    expect(await setWarmSchedule({ enabled: true, times: ['nope'], days: [0], timeZone: 'UTC' }, path)).toBeNull()
    expect((await loadWarmState(path)).schedule?.times).toEqual(['07:00'])
  })

  it('records results newest first and shares one in-flight warm', async () => {
    let release!: () => void
    const gate = new Promise<void>(r => { release = r })
    const send = vi.fn(async (): Promise<SendResult> => { await gate; return { ok: true } })
    const deps = { send, readFiveHour: async (): Promise<FiveHourReading> => ({ state: 'idle' }), sleep: async () => {} }
    const a = runWarm({ trigger: 'manual', force: true }, deps, path)
    const b = runWarm({ trigger: 'manual', force: true }, deps, path)
    release()
    expect(await a).toBe(await b)
    expect(send).toHaveBeenCalledTimes(1)
    expect((await loadWarmState(path)).history).toHaveLength(1)
  })

  it('fires each due slot once', async () => {
    await setWarmSchedule(schedule({ timeZone: 'UTC', times: ['07:00'] }), path)
    const warm = vi.fn(async () => {})
    let now = new Date('2026-10-31T07:01:00Z')
    const scheduler = startWarmScheduler({ statePath: path, now: () => now, intervalMs: 60 * 60_000, warm })
    try {
      await scheduler.tick()
      now = new Date('2026-10-31T07:05:00Z')
      await scheduler.tick()
      expect(warm).toHaveBeenCalledTimes(1)
      expect(warm).toHaveBeenCalledWith('2026-10-31 07:00')
      now = new Date('2026-11-01T07:02:00Z')
      await scheduler.tick()
      expect(warm).toHaveBeenCalledTimes(2)
    } finally {
      scheduler.stop()
    }
  })
})
