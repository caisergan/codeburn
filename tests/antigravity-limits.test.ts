import { describe, expect, it } from 'vitest'

import {
  computeAntigravityLimits,
  groupForModel,
  parseAntigravityReadingLine,
  type AntigravityReading,
} from '../src/antigravity-limits.js'
import type { LimitCall } from '../src/claude-limits.js'

const t = (s: string): number => Date.parse(s)

const GROUPS = [
  { id: 'gemini', name: 'Gemini Models', models: ['Gemini 3.1 Pro (High)', 'Gemini 3.5 Flash (High)'] },
  { id: '3p', name: 'Claude and GPT models', models: ['Claude Sonnet 4.6', 'GPT-OSS 120B (Medium)'] },
]

function line(at: string, groups: Array<{ id: string; five?: [number, string | null]; week?: [number, string | null] }>, plan = 'Google AI Pro'): string {
  return JSON.stringify({
    at,
    ok: true,
    plan,
    groups: groups.map(g => ({
      id: g.id,
      name: GROUPS.find(x => x.id === g.id)?.name ?? g.id,
      models: GROUPS.find(x => x.id === g.id)?.models ?? [],
      ...(g.five ? { five_hour: { pct: g.five[0], resetsAt: g.five[1] } } : {}),
      ...(g.week ? { seven_day: { pct: g.week[0], resetsAt: g.week[1] } } : {}),
    })),
  })
}

function readingOf(text: string): AntigravityReading {
  const parsed = parseAntigravityReadingLine(text)
  if (!parsed?.reading) throw new Error('not a reading')
  return parsed.reading
}

function call(at: string, costUSD: number, model = 'gemini-4-neon', chatId = 'chat-a'): LimitCall {
  return {
    at: t(at),
    costUSD,
    tokens: { input: 10, output: 20, cacheRead: 1000, cacheWrite: 0 },
    model,
    unpriced: false,
    chatId,
    chatTitle: `title ${chatId}`,
  }
}

describe('reading log', () => {
  it('reads groups with their 5-hour and weekly buckets', () => {
    const r = readingOf(line('2026-11-27T22:00:00Z', [
      { id: 'gemini', five: [12, '2026-11-28T02:02:39Z'], week: [9, '2026-12-04T15:04:49Z'] },
    ]))
    expect(r.plan).toBe('Google AI Pro')
    expect(r.groups[0]).toMatchObject({ id: 'gemini', name: 'Gemini Models', fiveHour: { pct: 12 }, sevenDay: { pct: 9 } })
  })

  it('drops idle buckets: full, with a reset sliding to now + the window, or none', () => {
    const r = readingOf(line('2026-11-27T22:00:00Z', [
      { id: 'gemini', five: [0, '2026-11-28T03:00:00Z'], week: [0, null] },
      { id: '3p', five: [0, '2026-11-28T01:00:00Z'] },
    ]))
    expect(r.groups[0]!.fiveHour).toBeUndefined()
    expect(r.groups[0]!.sevenDay).toBeUndefined()
    // A started window at 0% (tiny use) keeps its fixed reset.
    expect(r.groups[1]!.fiveHour).toEqual({ pct: 0, resetsAt: t('2026-11-28T01:00:00Z') })
  })

  it('reads failures and skips malformed lines', () => {
    expect(parseAntigravityReadingLine('{"at":"2026-11-27T22:00:00Z","ok":false,"reason":"auth"}')?.failure)
      .toEqual({ at: t('2026-11-27T22:00:00Z'), reason: 'auth' })
    expect(parseAntigravityReadingLine('{"at":"2026-11-27T22:00')).toBeNull()
    expect(parseAntigravityReadingLine('{"ok":true,"groups":[]}')).toBeNull()
  })
})

describe('groups', () => {
  it('puts each model in the group that lists its family', () => {
    expect(groupForModel('gemini-4-neon', GROUPS)).toBe('gemini')
    expect(groupForModel('claude-sonnet-4-6', GROUPS)).toBe('3p')
    expect(groupForModel('gpt-oss-120b-medium', GROUPS)).toBe('3p')
  })

  it('falls back to the group ids when no models are listed', () => {
    const bare = GROUPS.map(g => ({ ...g, models: [] }))
    expect(groupForModel('gemini-3.8-flash-n', bare)).toBe('gemini')
    expect(groupForModel('claude-opus-4-6', bare)).toBe('3p')
  })
})

describe('computeAntigravityLimits', () => {
  // Measured 2026-11-27: the first call at 15:04:48.97 opened a week that
  // Antigravity reported as resetting at 15:04:49 seven days later.
  const readings = [
    readingOf(line('2026-11-27T15:10:00Z', [
      { id: 'gemini', five: [4, '2026-11-27T20:04:49Z'], week: [3, '2026-12-04T15:04:49Z'] },
      { id: '3p', five: [0, '2026-11-27T20:10:00Z'], week: [0, null] },
    ])),
    readingOf(line('2026-11-27T19:00:00Z', [
      { id: 'gemini', five: [40, '2026-11-27T20:04:49Z'], week: [30, '2026-12-04T15:04:49Z'] },
    ])),
  ]
  const calls = [
    call('2026-11-27T15:04:48.972Z', 1),
    call('2026-11-27T18:30:00Z', 9),
    call('2026-11-27T16:00:00Z', 5, 'claude-sonnet-4-6', 'chat-b'),
  ]
  const out = computeAntigravityLimits({ now: t('2026-11-27T19:30:00Z'), readings, failures: [], calls })

  it('keeps the call that opened a window inside it', () => {
    const gemini = out.groups.find(g => g.id === 'gemini')!.report
    expect(gemini.sessions).toHaveLength(1)
    const session = gemini.sessions[0]!
    expect(session.startInferred).toBe(false)
    expect(session.start).toBe('2026-11-27T15:04:00.000Z')
    expect(session.spentUSD).toBe(10)
    expect(session.fiveHourPct).toBe(40)
    expect(gemini.current.week?.start).toBe('2026-11-27T15:04:00.000Z')
    expect(gemini.current.week?.spentUSD).toBe(10)
    expect(gemini.current.week?.usedPct).toBe(30)
  })

  it('splits spend by quota group', () => {
    const third = out.groups.find(g => g.id === '3p')!
    expect(third.name).toBe('Claude and GPT models')
    expect(third.report.sessions).toHaveLength(1)
    expect(third.report.sessions[0]!.spentUSD).toBe(5)
    // No reading names its window, so it is inferred from the call.
    expect(third.report.sessions[0]!.startInferred).toBe(true)
    expect(third.report.sessions[0]!.start).toBe('2026-11-27T16:00:00.000Z')
  })

  it('reports the plan and the newest reading', () => {
    expect(out.plan).toBe('Google AI Pro')
    expect(out.readingsThrough).toBe('2026-11-27T19:00:00.000Z')
  })

  it('still lists both groups before any reading', () => {
    const bare = computeAntigravityLimits({ now: t('2026-11-27T19:30:00Z'), readings: [], failures: [], calls })
    expect(bare.groups.map(g => g.id)).toEqual(['gemini', '3p'])
    expect(bare.groups[0]!.report.sessions[0]!.spentUSD).toBe(10)
  })
})
