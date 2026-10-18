import { describe, expect, it } from 'vitest'

import {
  computeClaudeLimits,
  type LimitCall,
  type LimitEvent,
  type LimitReading,
  type LimitSlot,
  type LimitsInput,
  type PeerLimitData,
} from '../src/claude-limits.js'

const t = (s: string): number => Date.parse(s)

function reading(at: string, five?: [number, string], week?: [number, string]): LimitReading {
  return {
    at: t(at),
    ...(five ? { fiveHour: { pct: five[0], resetsAt: t(five[1]) } } : {}),
    ...(week ? { sevenDay: { pct: week[0], resetsAt: t(week[1]) } } : {}),
  }
}

function call(at: string, costUSD: number, chatId = 'chat-a'): LimitCall {
  return {
    at: t(at),
    costUSD,
    tokens: { input: 10, output: 20, cacheRead: 1000, cacheWrite: 100 },
    model: 'claude-opus-5-5',
    modelName: 'Opus 5.5',
    unpriced: false,
    chatId,
    chatTitle: `title ${chatId}`,
  }
}

function slot(firstAt: string, costUSD: number, lastAt = firstAt, model = 'claude-opus-5-5'): LimitSlot {
  const first = t(firstAt)
  return {
    at: Math.floor(first / 600_000) * 600_000,
    firstAt: first,
    lastAt: t(lastAt),
    model,
    modelName: model === 'claude-opus-5-5' ? 'Opus 5.5' : model,
    costUSD,
    unpriced: false,
    tokens: { input: 5, output: 5, cacheRead: 500, cacheWrite: 50 },
  }
}

function peer(partial: Partial<PeerLimitData> = {}): PeerLimitData {
  return {
    id: 'fp-vm',
    name: 'instance-vm',
    addedAt: t('2026-10-01T00:00:00Z'),
    status: 'ok',
    through: t('2026-10-15T06:58:00Z'),
    lastCallAt: null,
    lastSyncedAt: t('2026-10-15T06:58:00Z'),
    slots: [],
    events: [],
    ...partial,
  }
}

function input(partial: Partial<LimitsInput> & { now: string }): LimitsInput {
  return { readings: [], failures: [], events: [], calls: [], localName: 'mac', ...partial, now: t(partial.now) }
}

const WEEK_RESET = '2026-10-21T08:00:00.000Z'
const FIVE_RESET = '2026-10-15T07:00:00.000Z'

describe('a paired device’s spend', () => {
  const readings = [
    reading('2026-10-15T02:05:00Z', [0, FIVE_RESET], [10, WEEK_RESET]),
    reading('2026-10-15T06:50:00Z', [40, FIVE_RESET], [14, WEEK_RESET]),
  ]

  it('counts toward the session, with a split by device, a chat line and hour and model parts', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-15T07:00:00Z',
      readings,
      calls: [call('2026-10-15T02:10:00Z', 30)],
      peers: [peer({ slots: [slot('2026-10-15T03:12:00Z', 10, '2026-10-15T03:18:00Z')] })],
    }))
    const s = out.sessions.find(x => x.id === FIVE_RESET)!
    expect(s.spentUSD).toBe(40)
    expect(s.fullSessionUSD).toBe(100)
    expect(s.fullSessionQuality).toBe('estimated')
    expect(s.devices).toEqual([
      { id: 'local', name: 'mac', local: true, spentUSD: 30 },
      { id: 'fp-vm', name: 'instance-vm', local: false, spentUSD: 10 },
    ])
    const deviceChat = s.chats.find(c => c.device)!
    expect(deviceChat).toMatchObject({ title: 'instance-vm', spentUSD: 10, device: { id: 'fp-vm', name: 'instance-vm' }, promptCount: 0 })
    expect(deviceChat.firstAt).toBe('2026-10-15T03:12:00.000Z')
    expect(deviceChat.lastAt).toBe('2026-10-15T03:18:00.000Z')
    expect(deviceChat.project).toBeUndefined()
    expect(deviceChat.path).toBeUndefined()
    expect(s.hours[1]).toMatchObject({ spentUSD: 10, peerSpentUSD: 10 })
    expect(s.hours[0]!.peerSpentUSD).toBeUndefined()
    expect(s.models).toEqual([{ model: 'Opus 5.5', spentUSD: 40, tokens: 1130 + 560, peerSpentUSD: 10 }])
    expect(s.deviceNotes).toBeUndefined()
    expect(s.spentLowerBound).toBeUndefined()
    expect(out.devices).toEqual([{
      id: 'fp-vm',
      name: 'instance-vm',
      status: 'ok',
      through: '2026-10-15T06:58:00.000Z',
      lastCallAt: null,
      lastSyncedAt: '2026-10-15T06:58:00.000Z',
    }])
  })

  it('keeps a session spent only on the device from reading as used outside', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-15T07:00:00Z',
      readings,
      calls: [],
      peers: [peer({ slots: [slot('2026-10-15T02:30:00Z', 22)] })],
    }))
    const s = out.sessions.find(x => x.id === FIVE_RESET)!
    expect(s.spentUSD).toBe(22)
    expect(s.outsideThisMac).toBe(false)
    expect(s.weekPct).toBe(4)
    expect(s.weekQuality).toBe('measured')
  })

  it('brackets the week share by the device’s first and last call, not its slot', () => {
    // The 02:05 reading is before the slot's first call at 02:31, so it
    // brackets; the slot started at 02:30 but nothing ran before 02:31.
    const out = computeClaudeLimits(input({
      now: '2026-10-15T07:00:00Z',
      readings: [
        reading('2026-10-15T02:30:30Z', [0, FIVE_RESET], [10, WEEK_RESET]),
        reading('2026-10-15T06:50:00Z', [40, FIVE_RESET], [14, WEEK_RESET]),
      ],
      peers: [peer({ slots: [slot('2026-10-15T02:31:00Z', 22, '2026-10-15T02:39:00Z')] })],
    }))
    expect(out.sessions[0]!.weekQuality).toBe('measured')
  })

  it('infers a session from a device’s spend when nothing names its window', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-15T09:00:00Z',
      peers: [peer({ through: t('2026-10-15T08:59:00Z'), slots: [slot('2026-10-15T03:12:00Z', 5)] })],
    }))
    expect(out.sessions).toHaveLength(1)
    expect(out.sessions[0]).toMatchObject({ start: '2026-10-15T03:10:00.000Z', startInferred: true, spentUSD: 5 })
  })

  it('adds the device’s spend to weeks and the same-point comparison', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-15T07:00:00Z',
      readings,
      calls: [call('2026-10-15T02:10:00Z', 30), call('2026-10-08T02:10:00Z', 50)],
      peers: [peer({ slots: [slot('2026-10-15T03:12:00Z', 10), slot('2026-10-08T03:00:00Z', 7)] })],
    }))
    const week = out.current.week!
    expect(week.spentUSD).toBe(40)
    expect(week.devices?.map(d => d.spentUSD)).toEqual([30, 10])
    expect(week.days.find(d => d.peerSpentUSD)?.peerSpentUSD).toBe(10)
    expect(week.previousAtSamePoint?.spentUSD).toBe(57)
    expect(week.previousAtSamePoint?.devices?.map(d => d.spentUSD)).toEqual([50, 7])
  })
})

describe('a paired device’s limit hits', () => {
  it('give the exact 100% point; the first refusal across devices wins', () => {
    const local: LimitEvent = { limit: 'five_hour', at: t('2026-10-15T05:00:00Z'), resetsAt: t(FIVE_RESET) }
    const remote: LimitEvent = { limit: 'five_hour', at: t('2026-10-15T04:40:00Z'), resetsAt: t('2026-10-15T06:59:59.4Z') }
    const out = computeClaudeLimits(input({
      now: '2026-10-15T07:00:00Z',
      calls: [call('2026-10-15T02:10:00Z', 60)],
      events: [local],
      peers: [peer({ slots: [slot('2026-10-15T03:00:00Z', 20)], events: [remote] })],
    }))
    const s = out.sessions.find(x => x.id === FIVE_RESET)!
    expect(s.fiveHourPct).toBe(100)
    expect(s.ranOut).toEqual({ limit: 'five_hour', at: '2026-10-15T04:40:00.000Z', spentUSD: 80 })
    expect(s.fullSessionQuality).toBe('exact')
  })

  it('make the spend at the hit approximate when a device’s slot straddles it', () => {
    const hit: LimitEvent = { limit: 'five_hour', at: t('2026-10-15T04:45:00Z'), resetsAt: t(FIVE_RESET) }
    const out = computeClaudeLimits(input({
      now: '2026-10-15T07:00:00Z',
      calls: [call('2026-10-15T02:10:00Z', 60)],
      events: [hit],
      peers: [peer({ slots: [slot('2026-10-15T04:41:00Z', 9, '2026-10-15T04:48:00Z')] })],
    }))
    const s = out.sessions.find(x => x.id === FIVE_RESET)!
    expect(s.ranOut).toEqual({ limit: 'five_hour', at: '2026-10-15T04:45:00.000Z', spentUSD: 69, approximate: true })
    expect(s.fullSessionQuality).toBe('estimated')
  })
})

describe('missing device data', () => {
  const readings = [
    reading('2026-10-15T02:05:00Z', [0, FIVE_RESET], [10, WEEK_RESET]),
    reading('2026-10-15T06:50:00Z', [40, FIVE_RESET], [14, WEEK_RESET]),
  ]
  const calls = [call('2026-10-15T02:10:00Z', 30)]

  it('marks spend a lower bound after a device’s data stops', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-15T07:00:00Z',
      readings,
      calls,
      peers: [peer({ status: 'unreachable', through: t('2026-10-15T04:20:00Z'), slots: [slot('2026-10-15T03:12:00Z', 10)] })],
    }))
    const s = out.sessions.find(x => x.id === FIVE_RESET)!
    expect(s.spentUSD).toBe(40)
    expect(s.spentLowerBound).toBe(true)
    expect(s.deviceNotes).toEqual([{ id: 'fp-vm', name: 'instance-vm', kind: 'stale', through: '2026-10-15T04:20:00.000Z' }])
    expect(s.fullSessionQuality).toBe('lowerBound')
    expect(out.current.week!.spentLowerBound).toBe(true)
  })

  it('tolerates data a few minutes behind the window’s end', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-15T06:00:00Z',
      readings,
      calls,
      peers: [peer({ through: t('2026-10-15T05:52:00Z') })],
    }))
    expect(out.current.session!.deviceNotes).toBeUndefined()
  })

  it('names an older or unauthorized device on sessions since it was paired', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-16T07:00:00Z',
      calls: [call('2026-10-14T02:10:00Z', 30), call('2026-10-16T02:10:00Z', 30)],
      peers: [
        peer({ status: 'unsupported', through: null, addedAt: t('2026-10-15T00:00:00Z') }),
        peer({ id: 'fp-2', name: 'studio', status: 'unauthorized', through: null, addedAt: t('2026-10-15T00:00:00Z') }),
      ],
    }))
    const [newer, older] = out.sessions
    expect(newer!.deviceNotes?.map(n => n.kind)).toEqual(['unsupported', 'unauthorized'])
    expect(newer!.spentLowerBound).toBe(true)
    expect(older!.deviceNotes).toBeUndefined()
  })

  it('names a never-synced device as unreachable', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-15T03:00:00Z',
      calls,
      peers: [peer({ status: 'not_synced', through: null })],
    }))
    expect(out.current.session!.deviceNotes).toEqual([{ id: 'fp-vm', name: 'instance-vm', kind: 'unreachable' }])
  })

  it('does not count a device on another Claude account, and says so on the running session only', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-16T03:00:00Z',
      calls: [call('2026-10-15T02:10:00Z', 30), call('2026-10-16T02:10:00Z', 30)],
      events: [],
      peers: [peer({
        status: 'other_account',
        through: t('2026-10-16T02:59:00Z'),
        slots: [slot('2026-10-16T02:30:00Z', 99)],
        events: [{ limit: 'five_hour', at: t('2026-10-16T02:40:00Z'), resetsAt: t('2026-10-16T07:00:00Z') }],
      })],
    }))
    const running = out.current.session!
    expect(running.spentUSD).toBe(30)
    expect(running.ranOut).toBeUndefined()
    expect(running.deviceNotes).toEqual([{ id: 'fp-vm', name: 'instance-vm', kind: 'other_account' }])
    expect(running.spentLowerBound).toBeUndefined()
    expect(out.sessions.find(s => !s.running)!.deviceNotes).toBeUndefined()
  })
})

describe('without paired devices', () => {
  it('adds nothing to the output', () => {
    const out = computeClaudeLimits(input({ now: '2026-10-15T03:00:00Z', calls: [call('2026-10-15T02:10:00Z', 30)] }))
    const s = out.current.session!
    expect(out.devices).toEqual([])
    expect(s.devices).toBeUndefined()
    expect(s.deviceNotes).toBeUndefined()
    expect(s.spentLowerBound).toBeUndefined()
    expect(s.hours.every(h => h.peerSpentUSD === undefined)).toBe(true)
    expect(s.models.every(m => m.peerSpentUSD === undefined)).toBe(true)
  })
})
