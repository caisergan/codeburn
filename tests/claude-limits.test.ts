import { describe, expect, it } from 'vitest'

import {
  buildSessionWindows,
  buildWeekWindows,
  computeClaudeLimits,
  windowKey,
  type LimitCall,
  type LimitEvent,
  type LimitReading,
  type LimitsInput,
} from '../src/claude-limits.js'

const t = (s: string): number => Date.parse(s)
const H = 60 * 60 * 1000

function reading(at: string, opts: { five?: [number, string]; week?: [number, string]; plan?: string; imported?: boolean } = {}): LimitReading {
  return {
    at: t(at),
    ...(opts.plan ? { plan: opts.plan } : {}),
    ...(opts.five ? { fiveHour: { pct: opts.five[0], resetsAt: t(opts.five[1]) } } : {}),
    ...(opts.week ? { sevenDay: { pct: opts.week[0], resetsAt: t(opts.week[1]) } } : {}),
    ...(opts.imported ? { imported: true } : {}),
  }
}

function call(at: string, costUSD: number, chatId = 'chat-a', opts: { model?: string; unpriced?: boolean } = {}): LimitCall {
  return {
    at: t(at),
    costUSD,
    tokens: { input: 10, output: 20, cacheRead: 1000, cacheWrite: 100 },
    model: opts.model ?? 'claude-opus-5-5',
    unpriced: opts.unpriced ?? false,
    chatId,
    chatTitle: `title ${chatId}`,
  }
}

function input(partial: Partial<LimitsInput> & { now: string }): LimitsInput {
  return {
    readings: [],
    failures: [],
    events: [],
    calls: [],
    ...partial,
    now: t(partial.now),
  }
}

const WEEK_RESET = '2026-10-21T08:00:00.000Z'
const PREV_WEEK_RESET = '2026-10-14T08:00:00.000Z'

describe('windows', () => {
  it('collapses sub-second reset jitter into one session', () => {
    const readings = [
      reading('2026-10-14T09:00:00Z', { five: [10, '2026-10-14T12:59:59.622Z'] }),
      reading('2026-10-14T10:00:00Z', { five: [30, '2026-10-14T13:00:00.000Z'] }),
    ]
    const windows = buildSessionWindows(readings, [], [call('2026-10-14T09:30:00Z', 5)])
    expect(windows).toHaveLength(1)
    expect(new Date(windows[0]!.start).toISOString()).toBe('2026-10-14T08:00:00.000Z')
    expect(windowKey(t('2026-10-14T12:59:59.622Z'))).toBe(t('2026-10-14T13:00:00Z'))
  })

  it('rounds window keys to the nearest 10 minutes', () => {
    expect(windowKey(t('2026-10-14T11:24:59Z'))).toBe(t('2026-10-14T11:20:00Z'))
    expect(windowKey(t('2026-10-14T11:25:01Z'))).toBe(t('2026-10-14T11:30:00Z'))
  })

  it('infers a window from calls, rounded down to a 10-minute mark and never to the hour', () => {
    const windows = buildSessionWindows([], [], [
      call('2026-10-14T00:27:13Z', 1),
      call('2026-10-14T04:00:00Z', 1),
      call('2026-10-14T05:40:00Z', 1),
    ])
    expect(windows.map(w => [new Date(w.start).toISOString(), new Date(w.end).toISOString(), w.inferred])).toEqual([
      ['2026-10-14T00:20:00.000Z', '2026-10-14T05:20:00.000Z', true],
      ['2026-10-14T05:40:00.000Z', '2026-10-14T10:40:00.000Z', true],
    ])
  })

  it('does not let an inferred window overlap a known one, or start inside the previous one', () => {
    const readings = [reading('2026-10-14T07:00:00Z', { five: [5, '2026-10-14T11:00:00Z'] })]
    const windows = buildSessionWindows(readings, [], [
      call('2026-10-14T04:01:00Z', 1),
      call('2026-10-14T06:30:00Z', 1),
      call('2026-10-14T11:03:00Z', 1),
    ])
    expect(windows.map(w => [new Date(w.start).toISOString(), new Date(w.end).toISOString(), w.inferred])).toEqual([
      ['2026-10-14T04:00:00.000Z', '2026-10-14T06:00:00.000Z', true],
      ['2026-10-14T06:00:00.000Z', '2026-10-14T11:00:00.000Z', false],
      ['2026-10-14T11:00:00.000Z', '2026-10-14T16:00:00.000Z', true],
    ])
  })

  it('assigns a boundary reading to the session its reset time names', () => {
    // Back-to-back sessions: a reading taken just after 11:00 names the new
    // session, and must not raise the finished one.
    const out = computeClaudeLimits(input({
      now: '2026-10-14T12:00:00Z',
      readings: [
        reading('2026-10-14T10:55:00Z', { five: [60, '2026-10-14T11:00:00Z'], week: [10, WEEK_RESET] }),
        reading('2026-10-14T11:01:00Z', { five: [2, '2026-10-14T16:00:00Z'], week: [11, WEEK_RESET] }),
      ],
      calls: [call('2026-10-14T10:50:00Z', 20), call('2026-10-14T11:00:30Z', 3)],
    }))
    const [current, previous] = out.sessions
    expect(current!.running).toBe(true)
    expect(current!.fiveHourPct).toBe(2)
    expect(previous!.fiveHourPct).toBe(60)
  })
})

describe('weeks', () => {
  it('follows the readings when the reset day moves, starting the new week at its nominal start', () => {
    const readings = [
      reading('2026-09-29T10:00:00Z', { week: [20, '2026-10-05T10:00:00Z'] }),
      reading('2026-09-30T02:00:00Z', { week: [41, '2026-10-05T10:00:00Z'] }),
      reading('2026-10-04T02:30:00Z', { week: [6, '2026-10-07T08:00:00Z'] }),
    ]
    const weeks = buildWeekWindows(readings, [], t('2026-10-05T00:00:00Z'))
    const moved = weeks.find(w => w.key === t('2026-10-05T10:00:00Z'))!
    const next = weeks.find(w => w.key === t('2026-10-07T08:00:00Z'))!
    expect(new Date(moved.end).toISOString()).toBe('2026-09-30T08:00:00.000Z')
    expect(moved.endReason).toBe('moved')
    expect(new Date(next.start).toISOString()).toBe('2026-09-30T08:00:00.000Z')
  })

  it('ends a week early when its percent drops before the reset', () => {
    const readings = [
      reading('2026-10-15T08:00:00Z', { week: [30, WEEK_RESET] }),
      reading('2026-10-16T08:00:00Z', { week: [0, WEEK_RESET] }),
    ]
    const weeks = buildWeekWindows(readings, [], t('2026-10-17T00:00:00Z'))
    const early = weeks.find(w => w.endReason === 'early_reset')!
    expect(new Date(early.end).toISOString()).toBe('2026-10-16T08:00:00.000Z')
    expect(weeks.at(-1)!.start).toBe(t('2026-10-16T08:00:00Z'))
  })

  it('ignores a one-point wobble', () => {
    const readings = [
      reading('2026-10-15T08:00:00Z', { week: [30, WEEK_RESET] }),
      reading('2026-10-15T09:00:00Z', { week: [29, WEEK_RESET] }),
    ]
    expect(buildWeekWindows(readings, [], t('2026-10-16T00:00:00Z')).some(w => w.endReason === 'early_reset')).toBe(false)
  })

  it('reports the current week and the three before it', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-15T00:00:00Z',
      readings: [reading('2026-10-14T20:00:00Z', { week: [8, WEEK_RESET] })],
      calls: [call('2026-10-14T19:00:00Z', 100), call('2026-10-01T12:00:00Z', 50)],
    }))
    expect(out.weeks).toHaveLength(4)
    expect(out.weeks[0]!.running).toBe(true)
    expect(out.weeks[0]!.usedPct).toBe(8)
    expect(out.weeks[0]!.fullWeekUSD).toBeCloseTo(1250)
    expect(out.weeks[2]!.spentUSD).toBe(50)
    expect(out.weeks[2]!.usedQuality).toBe('unknown')
  })
})

describe('week used per session', () => {
  it('is the difference between the readings bracketing the session', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-15T12:00:00Z',
      readings: [
        reading('2026-10-15T01:50:00Z', { week: [20, WEEK_RESET] }),
        reading('2026-10-15T02:30:00Z', { five: [10, '2026-10-15T07:00:00Z'], week: [21, WEEK_RESET] }),
        reading('2026-10-15T06:10:00Z', { five: [70, '2026-10-15T07:00:00Z'], week: [29, WEEK_RESET] }),
      ],
      calls: [call('2026-10-15T02:05:00Z', 30), call('2026-10-15T06:00:00Z', 90)],
    }))
    const s = out.sessions.find(x => x.id === '2026-10-15T07:00:00.000Z')!
    expect(s.weekPct).toBe(9)
    expect(s.weekQuality).toBe('measured')
    expect(s.weekFrom).toBe(20)
    expect(s.weekTo).toBe(29)
    expect(s.fiveHourPct).toBe(70)
    expect(s.fiveHourQuality).toBe('measured')
    expect(s.spentUSD).toBe(120)
    expect(s.fullSessionUSD).toBeCloseTo(120 / 70 * 100)
    expect(s.fullSessionQuality).toBe('estimated')
  })

  it('does not bracket across another session’s local spend', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-16T00:00:00Z',
      readings: [
        reading('2026-10-15T01:50:00Z', { week: [20, WEEK_RESET] }),
        reading('2026-10-15T02:30:00Z', { five: [40, '2026-10-15T07:00:00Z'], week: [24, WEEK_RESET] }),
        reading('2026-10-15T08:00:00Z', { five: [10, '2026-10-15T12:10:00Z'], week: [30, WEEK_RESET] }),
      ],
      calls: [call('2026-10-15T02:05:00Z', 30), call('2026-10-15T06:00:00Z', 30), call('2026-10-15T07:20:00Z', 30)],
    }))
    const s = out.sessions.find(x => x.id === '2026-10-15T07:00:00.000Z')!
    expect(s.fiveHourQuality).toBe('lowerBound')
    expect(s.weekQuality).toBe('estimated')
  })

  it('splits a session the week reset inside', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-14T12:00:00Z',
      readings: [
        reading('2026-10-14T05:50:00Z', { week: [80, PREV_WEEK_RESET] }),
        reading('2026-10-14T07:55:00Z', { five: [50, '2026-10-14T11:00:00Z'], week: [84, PREV_WEEK_RESET] }),
        reading('2026-10-14T10:30:00Z', { five: [90, '2026-10-14T11:00:00Z'], week: [5, WEEK_RESET] }),
      ],
      calls: [call('2026-10-14T06:30:00Z', 40), call('2026-10-14T07:50:00Z', 10), call('2026-10-14T10:20:00Z', 40)],
    }))
    const s = out.sessions.find(x => x.id === '2026-10-14T11:00:00.000Z')!
    expect(s.weekPct).toBe(5)
    expect(s.weekSplit).toEqual({ thisWeek: 5, lastWeek: 4, resetAt: PREV_WEEK_RESET })
  })
})

describe('limit events', () => {
  const readings = [
    reading('2026-10-15T02:00:00Z', { five: [20, '2026-10-15T07:00:00Z'], week: [10, WEEK_RESET] }),
  ]
  const calls = [call('2026-10-15T02:10:00Z', 50), call('2026-10-15T04:30:00Z', 40), call('2026-10-15T05:00:00Z', 30)]
  const events: LimitEvent[] = [
    { limit: 'five_hour', at: t('2026-10-15T05:30:00Z'), resetsAt: t('2026-10-15T07:00:00Z') },
    { limit: 'five_hour', at: t('2026-10-15T04:45:00Z'), resetsAt: t('2026-10-15T06:59:59.5Z') },
    { limit: 'five_hour', at: t('2026-10-15T06:00:00Z'), resetsAt: t('2026-10-15T07:00:00Z') },
  ]

  it('sets an exact 100% and the ran-out time from the first refused request', () => {
    const out = computeClaudeLimits(input({ now: '2026-10-16T00:00:00Z', readings, calls, events }))
    const s = out.sessions.find(x => x.id === '2026-10-15T07:00:00.000Z')!
    expect(s.fiveHourPct).toBe(100)
    expect(s.fiveHourQuality).toBe('exact')
    expect(s.ranOut).toEqual({ limit: 'five_hour', at: '2026-10-15T04:45:00.000Z', spentUSD: 90 })
    expect(s.fullSessionUSD).toBe(90)
    expect(s.fullSessionQuality).toBe('exact')
  })

  it('keeps five_hour and seven_day apart', () => {
    const weekly: LimitEvent = { limit: 'seven_day', at: t('2026-10-15T05:10:00Z'), resetsAt: t(WEEK_RESET) }
    const out = computeClaudeLimits(input({ now: '2026-10-16T00:00:00Z', readings, calls, events: [weekly] }))
    const s = out.sessions.find(x => x.id === '2026-10-15T07:00:00.000Z')!
    expect(s.fiveHourQuality).not.toBe('exact')
    expect(s.ranOut?.limit).toBe('seven_day')
    const week = out.weeks[0]!
    expect(week.usedPct).toBe(100)
    expect(week.usedQuality).toBe('exact')
    expect(week.ranOutAt).toBe('2026-10-15T05:10:00.000Z')
    expect(week.fullWeekUSD).toBe(120)
    expect(week.fullWeekQuality).toBe('exact')
  })
})

describe('gaps and display values', () => {
  it('never reports a measured value without readings', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-16T00:00:00Z',
      calls: [call('2026-10-15T02:10:00Z', 50)],
      failures: [
        { at: t('2026-10-15T02:00:00Z'), reason: 'rate_limited', retryAfter: 300 },
        { at: t('2026-10-15T02:10:00Z'), reason: 'rate_limited' },
      ],
    }))
    const s = out.sessions[0]!
    expect(s.fiveHourQuality).toBe('unknown')
    expect(s.fiveHourPct).toBeNull()
    expect(s.weekQuality).toBe('unknown')
    expect(s.startInferred).toBe(true)
    expect(s.gap).toEqual({ from: '2026-10-15T02:00:00.000Z', to: '2026-10-15T02:10:00.000Z', reason: 'rate_limited' })
  })

  it('estimates week use from the week’s points per dollar when readings are missing', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-16T00:00:00Z',
      readings: [reading('2026-10-14T12:00:00Z', { week: [10, WEEK_RESET] })],
      calls: [call('2026-10-14T11:00:00Z', 100), call('2026-10-15T20:00:00Z', 50)],
    }))
    const s = out.sessions.find(x => x.spentUSD === 50)!
    expect(s.weekQuality).toBe('estimated')
    expect(s.weekPct).toBe(5)
  })

  it('hides the full-session value under 20% and the full-week value under 5%', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-15T03:00:00Z',
      readings: [reading('2026-10-15T02:30:00Z', { five: [19, '2026-10-15T07:00:00Z'], week: [4, WEEK_RESET] })],
      calls: [call('2026-10-15T02:10:00Z', 30)],
    }))
    expect(out.current.session!.fullSessionUSD).toBeUndefined()
    expect(out.current.week!.fullWeekUSD).toBeUndefined()
  })

  it('lists unpriced models', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-15T03:00:00Z',
      calls: [call('2026-10-15T02:10:00Z', 30), call('2026-10-15T02:20:00Z', 0, 'chat-a', { model: 'claude-future', unpriced: true })],
    }))
    expect(out.current.session!.unpricedModels).toEqual(['claude-future'])
  })

  it('labels a session used outside this Mac', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-15T03:00:00Z',
      readings: [reading('2026-10-15T02:30:00Z', { five: [12, '2026-10-15T07:00:00Z'] })],
      calls: [call('2026-10-15T02:10:00Z', 0.2)],
    }))
    expect(out.current.session!.outsideThisMac).toBe(true)
  })

  it('orders chats by their share of the session’s spend, subagents already folded by the caller', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-15T03:00:00Z',
      calls: [call('2026-10-15T02:10:00Z', 5, 'a'), call('2026-10-15T02:11:00Z', 9, 'b'), call('2026-10-15T02:12:00Z', 1, 'a')],
    }))
    expect(out.current.session!.chats.map(c => [c.sessionId, c.spentUSD])).toEqual([['b', 9], ['a', 6]])
  })

  it('gives each chat the prompts typed in the window, its project and its active span', () => {
    const prompts = [
      { at: t('2026-10-15T01:55:00Z'), chatId: 'a', text: 'before the window' },
      ...Array.from({ length: 14 }, (_, i) => ({ at: t('2026-10-15T02:05:00Z') + i * 1000, chatId: 'a', text: `p${i}` })),
      { at: t('2026-10-15T02:20:00Z'), chatId: 'quiet', text: 'no spend here' },
    ]
    const calls = [call('2026-10-15T02:10:00Z', 5, 'a'), call('2026-10-15T02:40:00Z', 1, 'a')]
      .map(c => ({ ...c, chatProject: 'web', chatPath: '/Users/me/web' }))
    const out = computeClaudeLimits(input({
      now: '2026-10-15T03:00:00Z',
      readings: [reading('2026-10-15T02:01:00Z', { five: [1, '2026-10-15T07:00:00Z'] })],
      calls,
      prompts,
    }))
    const chats = out.current.session!.chats
    expect(chats.map(c => c.sessionId)).toEqual(['a'])
    expect(chats[0]).toMatchObject({
      project: 'web',
      path: '/Users/me/web',
      firstAt: '2026-10-15T02:10:00.000Z',
      lastAt: '2026-10-15T02:40:00.000Z',
      promptCount: 14,
    })
    expect(chats[0]!.prompts).toHaveLength(12)
    expect(chats[0]!.prompts[0]).toEqual({ at: '2026-10-15T02:05:00.000Z', text: 'p0' })
  })
})

// A week of well-measured sessions: each session reads its 5-hour percent and
// the week percent right before its first call and right after its last.
function measuredWeek(opts: { sessions: number; fivePct: number; weekStep: number; startPct?: number; plan?: string; planChangeAt?: number }) {
  const readings: LimitReading[] = []
  const calls: LimitCall[] = []
  let week = opts.startPct ?? 0
  const base = t('2026-10-14T08:00:00Z')
  for (let i = 0; i < opts.sessions; i++) {
    const start = base + i * 6 * H
    const reset = new Date(start + 5 * H).toISOString()
    const plan = opts.planChangeAt !== undefined && i >= opts.planChangeAt ? 'Max 20x' : (opts.plan ?? 'Max 5x')
    readings.push({ at: start + 1000, plan, fiveHour: { pct: 0, resetsAt: t(reset) }, sevenDay: { pct: week, resetsAt: t(WEEK_RESET) } })
    calls.push(call(new Date(start + 10 * 60 * 1000).toISOString(), 40, `c${i}`))
    calls.push(call(new Date(start + 3 * H).toISOString(), 60, `c${i}`))
    week += opts.weekStep
    readings.push({ at: start + 3 * H + 60_000, plan, fiveHour: { pct: opts.fivePct, resetsAt: t(reset) }, sevenDay: { pct: week, resetsAt: t(WEEK_RESET) } })
  }
  return { readings, calls, finalWeek: week }
}

describe('rate', () => {
  it('waits for five qualifying sessions', () => {
    const { readings, calls } = measuredWeek({ sessions: 4, fivePct: 50, weekStep: 6 })
    const out = computeClaudeLimits(input({ now: '2026-10-15T08:00:00Z', readings, calls }))
    expect(out.rate.weekPerSessionPoint).toBeNull()
    expect(out.rate.basis).toBe(4)
    expect(out.sessionsLeft).toBeNull()
  })

  it('is Σ week used ÷ Σ 5h used over at most ten sessions, and gives sessions left', () => {
    const { readings, calls } = measuredWeek({ sessions: 12, fivePct: 50, weekStep: 6 })
    const out = computeClaudeLimits(input({ now: '2026-10-17T08:00:00Z', readings, calls }))
    expect(out.rate.basis).toBe(10)
    expect(out.rate.weekPerSessionPoint).toBeCloseTo(0.12)
    // 72% used; a full session is 12% of the week: (100 − 72) / 12 → 2.
    expect(out.current.week!.usedPct).toBe(72)
    expect(out.sessionsLeft).toBe(2)
  })

  it('skips sessions under 30% of their 5-hour limit', () => {
    const { readings, calls } = measuredWeek({ sessions: 8, fivePct: 25, weekStep: 3 })
    const out = computeClaudeLimits(input({ now: '2026-10-17T08:00:00Z', readings, calls }))
    expect(out.rate.basis).toBe(0)
  })

  it('only counts the current and previous week', () => {
    const { readings, calls } = measuredWeek({ sessions: 6, fivePct: 50, weekStep: 6 })
    // Three weeks later the same sessions are two weeks back.
    const out = computeClaudeLimits(input({ now: '2026-11-01T08:00:00Z', readings, calls }))
    expect(out.rate.basis).toBe(0)
  })

  it('restarts when the plan tier changes', () => {
    const { readings, calls } = measuredWeek({ sessions: 8, fivePct: 50, weekStep: 6, planChangeAt: 5 })
    const out = computeClaudeLimits(input({ now: '2026-10-17T08:00:00Z', readings, calls }))
    expect(out.plan).toBe('Max 20x')
    expect(out.rate.basis).toBe(3)
    expect(out.rate.restartedAt).not.toBeNull()
    expect(out.rate.weekPerSessionPoint).toBeNull()
  })

  it('says when the week runs out before the session', () => {
    const { readings, calls } = measuredWeek({ sessions: 7, fivePct: 50, weekStep: 12, startPct: 0 })
    // Week at 84%, rate 0.24: a running session at 10% has (100 − 84) / 0.24 ≈ 67 points of week left.
    const last = t('2026-10-16T02:00:00Z')
    readings.push({ at: last + 60_000, plan: 'Max 5x', fiveHour: { pct: 10, resetsAt: last + 4 * H }, sevenDay: { pct: 84, resetsAt: t(WEEK_RESET) } })
    calls.push(call(new Date(last).toISOString(), 10, 'now'))
    const out = computeClaudeLimits(input({ now: '2026-10-16T02:30:00Z', readings, calls }))
    expect(out.rate.weekPerSessionPoint).toBeCloseTo(0.24)
    expect(out.runsOutFirstAtSessionPct).toBe(77)
  })
})

describe('closure', () => {
  it('sums the per-session week shares of a closed week to its final percent within ±2 points', () => {
    const { readings, calls, finalWeek } = measuredWeek({ sessions: 20, fivePct: 70, weekStep: 4.6 })
    // Whole percents, as Anthropic reports them.
    const rounded = readings.map(r => ({ ...r, sevenDay: r.sevenDay && { ...r.sevenDay, pct: Math.round(r.sevenDay.pct) } }))
    const out = computeClaudeLimits(input({ now: '2026-10-20T08:00:00Z', readings: rounded, calls }))
    const shares = out.sessions.filter(s => s.weekQuality === 'measured').reduce((sum, s) => sum + (s.weekPct ?? 0), 0)
    expect(Math.abs(shares - Math.round(finalWeek))).toBeLessThanOrEqual(2)
  })
})

describe('breakdowns', () => {
  const readings = [
    reading('2026-10-15T01:50:00Z', { week: [20, WEEK_RESET] }),
    reading('2026-10-15T02:30:00Z', { five: [10, '2026-10-15T07:00:00Z'], week: [21, WEEK_RESET] }),
    reading('2026-10-15T06:10:00Z', { five: [70, '2026-10-15T07:00:00Z'], week: [29, WEEK_RESET] }),
  ]
  const calls = [
    call('2026-10-15T02:05:00Z', 30, 'chat-a', { model: 'claude-opus-5' }),
    call('2026-10-15T06:00:00Z', 90, 'chat-a', { model: 'claude-sonnet-5' }),
    call('2026-10-15T06:05:00Z', 5, 'chat-a', { model: 'claude-opus-5' }),
  ].map(c => ({ ...c, modelName: c.model === 'claude-opus-5' ? 'Opus 5' : 'Sonnet 5' }))

  it('cuts a session into hours with the 5-hour percent read inside each', () => {
    const out = computeClaudeLimits(input({ now: '2026-10-15T12:00:00Z', readings, calls }))
    const s = out.sessions.find(x => x.id === '2026-10-15T07:00:00.000Z')!
    expect(s.hours.map(h => [h.start, h.spentUSD, h.fiveHourPct])).toEqual([
      ['2026-10-15T02:00:00.000Z', 30, 10],
      ['2026-10-15T03:00:00.000Z', 0, null],
      ['2026-10-15T04:00:00.000Z', 0, null],
      ['2026-10-15T05:00:00.000Z', 0, null],
      ['2026-10-15T06:00:00.000Z', 95, 70],
    ])
    expect(s.hours[0]!.tokens).toBe(1130)
  })

  it('stops a running session’s hours at now', () => {
    const out = computeClaudeLimits(input({ now: '2026-10-15T03:15:00Z', readings: readings.slice(0, 2), calls: calls.slice(0, 1) }))
    expect(out.current.session!.hours.map(h => h.start)).toEqual(['2026-10-15T02:00:00.000Z', '2026-10-15T03:00:00.000Z'])
  })

  it('puts a session at 100% from the hour its limit ran out', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-15T12:00:00Z',
      readings,
      calls,
      events: [{ limit: 'five_hour', at: t('2026-10-15T04:30:00Z'), resetsAt: t('2026-10-15T07:00:00Z') }],
    }))
    const s = out.sessions.find(x => x.id === '2026-10-15T07:00:00.000Z')!
    expect(s.hours.map(h => h.fiveHourPct)).toEqual([10, null, 100, 100, 100])
  })

  it('splits spend by model, most expensive first', () => {
    const out = computeClaudeLimits(input({ now: '2026-10-15T12:00:00Z', readings, calls }))
    const s = out.sessions.find(x => x.id === '2026-10-15T07:00:00.000Z')!
    expect(s.models).toEqual([
      { model: 'Sonnet 5', spentUSD: 90, tokens: 1130 },
      { model: 'Opus 5', spentUSD: 35, tokens: 2260 },
    ])
    expect(out.current.week!.models.map(m => m.model)).toEqual(['Sonnet 5', 'Opus 5'])
  })

  it('cuts a week into days from its reset, up to now', () => {
    const out = computeClaudeLimits(input({ now: '2026-10-16T12:00:00Z', readings, calls }))
    const week = out.current.week!
    expect(week.days.map(d => [d.start, d.spentUSD, d.usedPct])).toEqual([
      ['2026-10-14T08:00:00.000Z', 125, 29],
      ['2026-10-15T08:00:00.000Z', 0, null],
      ['2026-10-16T08:00:00.000Z', 0, null],
    ])
  })

  it('lists a week’s sessions with their share of it', () => {
    const out = computeClaudeLimits(input({ now: '2026-10-16T12:00:00Z', readings, calls }))
    expect(out.current.week!.sessions).toEqual([{
      id: '2026-10-15T07:00:00.000Z',
      start: '2026-10-15T02:00:00.000Z',
      end: '2026-10-15T07:00:00.000Z',
      running: false,
      spentUSD: 125,
      weekPct: 9,
      weekQuality: 'measured',
    }])
  })

  it('gives a session the week reset inside to both weeks, with its part of each', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-14T12:00:00Z',
      readings: [
        reading('2026-10-14T05:50:00Z', { week: [80, PREV_WEEK_RESET] }),
        reading('2026-10-14T07:55:00Z', { five: [50, '2026-10-14T11:00:00Z'], week: [84, PREV_WEEK_RESET] }),
        reading('2026-10-14T10:30:00Z', { five: [90, '2026-10-14T11:00:00Z'], week: [5, WEEK_RESET] }),
      ],
      calls: [call('2026-10-14T06:30:00Z', 40), call('2026-10-14T07:50:00Z', 10), call('2026-10-14T10:20:00Z', 40)],
    }))
    expect(out.weeks[0]!.sessions.map(s => s.weekPct)).toEqual([5])
    expect(out.weeks[1]!.sessions.map(s => s.weekPct)).toEqual([4])
  })

  it('compares the running week with the previous one at the same point', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-16T08:00:00Z',
      readings: [
        reading('2026-10-08T09:00:00Z', { week: [30, PREV_WEEK_RESET] }),
        reading('2026-10-09T07:00:00Z', { week: [41, PREV_WEEK_RESET] }),
        reading('2026-10-10T07:00:00Z', { week: [60, PREV_WEEK_RESET] }),
        reading('2026-10-16T07:00:00Z', { week: [32, WEEK_RESET] }),
      ],
      calls: [call('2026-10-08T08:30:00Z', 300), call('2026-10-09T06:00:00Z', 225), call('2026-10-09T09:00:00Z', 500), call('2026-10-16T06:00:00Z', 409)],
    }))
    expect(out.current.week!.previousAtSamePoint).toEqual({
      at: '2026-10-09T08:00:00.000Z',
      spentUSD: 525,
      usedPct: 41,
      usedQuality: 'measured',
    })
  })

  it('averages the full-week values of past weeks that have one', () => {
    const out = computeClaudeLimits(input({
      now: '2026-10-16T08:00:00Z',
      readings: [
        reading('2026-10-13T07:00:00Z', { week: [50, PREV_WEEK_RESET] }),
        reading('2026-10-16T07:00:00Z', { week: [10, WEEK_RESET] }),
      ],
      calls: [call('2026-10-12T06:00:00Z', 600), call('2026-10-16T06:00:00Z', 100)],
    }))
    expect(out.fullWeekAverage).toEqual({ usd: 1200, basis: 1 })
  })
})

describe('local days', () => {
  function inZone<T>(zone: string, run: () => T): T {
    const previous = process.env['TZ']
    process.env['TZ'] = zone
    try {
      return run()
    } finally {
      if (previous === undefined) delete process.env['TZ']
      else process.env['TZ'] = previous
    }
  }

  // 21:10–02:10 in Istanbul (UTC+3): midnight falls at 21:00Z.
  const readings = [reading('2026-10-16T18:30:00Z', { five: [10, '2026-10-16T23:10:00Z'] })]
  const calls = [call('2026-10-16T19:00:00Z', 10), call('2026-10-16T21:30:00Z', 17.5), call('2026-10-16T22:40:00Z', 10)]
  const id = '2026-10-16T23:10:00.000Z'

  it('gives a session that crosses local midnight what it spent after it', () => {
    const out = inZone('Europe/Istanbul', () => computeClaudeLimits(input({ now: '2026-10-17T12:00:00Z', readings, calls })))
    const s = out.sessions.find(x => x.id === id)!
    expect(s.spentUSD).toBe(37.5)
    expect(s.afterMidnight).toEqual({ at: '2026-10-16T21:00:00.000Z', spentUSD: 27.5 })
  })

  it('leaves it out for a session inside one day, and while midnight is still ahead', () => {
    const utc = inZone('UTC', () => computeClaudeLimits(input({ now: '2026-10-17T12:00:00Z', readings, calls })))
    expect(utc.sessions.find(x => x.id === id)!.afterMidnight).toBeUndefined()
    const running = inZone('Europe/Istanbul', () => computeClaudeLimits(input({ now: '2026-10-16T20:00:00Z', readings, calls: calls.slice(0, 1) })))
    expect(running.current.session!.id).toBe(id)
    expect(running.current.session!.afterMidnight).toBeUndefined()
  })
})
