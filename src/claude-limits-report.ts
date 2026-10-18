// `codeburn limits`: Claude 5-hour sessions and weeks at API prices.

import { hostname } from 'os'

import { collectLimitCalls, collectLimitEvents, collectLimitPrompts, readClaudeAccountHash, readReadingLog } from './claude-limit-sources.js'
import { readMonocodeTitles } from './monocode-titles.js'
import { computeClaudeLimits, WEEK_LIST_COUNT, WEEK_MS, type DeviceSpend, type DeviceStatus, type LimitsOutput, type Quality, type SessionOut, type WeekOut } from './claude-limits.js'
import { parseAllSessions } from './parser.js'
import { getClaudeConfigDirs } from './providers/claude.js'
import { readPeerLimitData, refreshPeerCaches } from './sharing/claude-limit-peers.js'

/// Enough history for the current week, the three before it, and the week
/// before those, which the per-session estimates fall back to.
export const LOOKBACK_MS = (WEEK_LIST_COUNT + 1) * WEEK_MS + 24 * 60 * 60 * 1000

/// `devices`: first ask paired devices for their latest spend (network);
/// otherwise their cached data is used as is.
export async function buildLimitsReport(now = new Date(), opts: { devices?: boolean } = {}): Promise<LimitsOutput> {
  // Whole local days, like every other command's range: the parser memoizes
  // on the range, so a range ending at "now" would re-parse on every request.
  const lookbackStart = new Date(now.getTime() - LOOKBACK_MS)
  const start = new Date(lookbackStart.getFullYear(), lookbackStart.getMonth(), lookbackStart.getDate())
  const end = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 23, 59, 59, 999)
  const since = start.getTime()
  const dirs = await getClaudeConfigDirs()
  const defaultDir = dirs[0]
  const refreshed = opts.devices
    ? readClaudeAccountHash(defaultDir).then(ownAccountHash => refreshPeerCaches({ now: now.getTime(), lookbackMs: LOOKBACK_MS, ownAccountHash }))
    : Promise.resolve()
  const [log, events, projects] = await Promise.all([
    readReadingLog(),
    defaultDir ? collectLimitEvents([defaultDir], since) : Promise.resolve([]),
    parseAllSessions({ start, end }, 'claude'),
    refreshed,
  ])
  const peers = await readPeerLimitData()
  const account = dirs.length > 1 ? defaultDir : undefined
  // Monocode names the chats it runs; Claude Code names only terminal chats.
  const titles = readMonocodeTitles()
  return computeClaudeLimits({
    now: now.getTime(),
    readings: log.readings.filter(r => r.at >= since),
    failures: log.failures.filter(f => f.at >= since),
    events,
    calls: collectLimitCalls(projects, account, titles),
    prompts: collectLimitPrompts(projects, account, titles),
    peers,
    localName: hostname(),
  })
}

function mark(quality: Quality): string {
  switch (quality) {
    case 'estimated': return '≈'
    case 'lowerBound': return '≥'
    default: return ''
  }
}

function pct(value: number | null, quality: Quality, signed = false): string {
  if (value === null || quality === 'unknown') return '–'
  return `${mark(quality)}${signed ? '+' : ''}${Math.round(value)}%`
}

function usd(value: number, unpriced: string[] = [], lowerBound = false): string {
  return `${unpriced.length > 0 || lowerBound ? '≥ ' : ''}$${value.toFixed(2)}`
}

/// "Mac $30.00 · instance $12.00" when a paired device spent in the window.
function deviceSplitText(devices: DeviceSpend[] | undefined): string {
  if (!devices) return ''
  return devices.map(d => `${d.local ? 'this device' : d.name} $${d.spentUSD.toFixed(2)}`).join(' · ')
}

const DEVICE_STATUS_TEXT: Record<DeviceStatus, string> = {
  ok: 'synced',
  unreachable: 'unreachable',
  unsupported: 'runs an older CodeBurn without Claude session data',
  unauthorized: 'no longer accepts this device; pair it again',
  other_account: 'on another Claude account, not counted',
  not_synced: 'not synced yet (run with --devices)',
}

function localTime(isoString: string): string {
  const d = new Date(isoString)
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}

function localDay(isoString: string): string {
  const d = new Date(isoString)
  return d.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' })
}

function sessionLabel(s: SessionOut): string {
  const approx = s.startInferred ? '≈' : ''
  return `${s.running ? '● ' : '  '}${localDay(s.start)} ${approx}${localTime(s.start)}–${localTime(s.end)}`
}

function weekLabel(w: WeekOut): string {
  return w.running ? `This week · since ${localDay(w.start)}` : `${localDay(w.start)} → ${localDay(w.end)}`
}

export async function renderLimitsTable(report: LimitsOutput): Promise<string> {
  const { renderTable } = await import('./text-table.js')
  const lines: string[] = []
  const { session, week } = report.current
  if (session) {
    lines.push(`Current session  ${pct(session.fiveHourPct, session.fiveHourQuality)} · ${usd(session.spentUSD, session.unpricedModels, session.spentLowerBound)} · ${pct(session.weekPct, session.weekQuality, true)} of week · ends ${localTime(session.end)}`)
  } else {
    lines.push('No session running')
  }
  if (week) {
    const full = week.fullWeekUSD === undefined ? '' : ` · full week ${mark(week.fullWeekQuality)}$${week.fullWeekUSD.toFixed(0)}`
    lines.push(`Current week     ${pct(week.usedPct, week.usedQuality)} · ${usd(week.spentUSD, week.unpricedModels, week.spentLowerBound)}${full} · resets ${localDay(week.end)} ${localTime(week.end)}`)
  }
  for (const d of report.devices) {
    const synced = d.lastSyncedAt ? ` · last synced ${localDay(d.lastSyncedAt)} ${localTime(d.lastSyncedAt)}` : ''
    lines.push(`Paired device    ${d.name} · ${DEVICE_STATUS_TEXT[d.status]}${synced}`)
  }
  const rate = report.rate.weekPerSessionPoint
  if (rate === null) {
    lines.push('Not enough sessions yet to measure what a full session is worth of your week')
  } else if (report.runsOutFirstAtSessionPct !== null) {
    lines.push(`Week runs out first, at about ${report.runsOutFirstAtSessionPct}% of this session`)
  } else {
    lines.push(`A full 5-hour session ≈ ${Math.round(rate * 100)}% of your week · ≈ ${report.sessionsLeft ?? 0} left`)
  }
  if (!report.readingsThrough) {
    lines.push('No limit readings yet: the CodeBurn menu bar app records them while it runs.')
  }
  lines.push('')
  lines.push(renderTable(
    [
      { header: '5-hour sessions · API prices' },
      { header: 'Spent', right: true },
      { header: '5h', right: true },
      { header: 'Week', right: true },
      { header: 'Full session', right: true },
      { header: '' },
    ],
    report.sessions.map(s => [
      sessionLabel(s),
      usd(s.spentUSD, s.unpricedModels, s.spentLowerBound),
      pct(s.fiveHourPct, s.fiveHourQuality),
      pct(s.weekPct, s.weekQuality, true),
      s.fullSessionUSD === undefined ? '–' : `${mark(s.fullSessionQuality)}$${s.fullSessionUSD.toFixed(0)}`,
      [
        s.ranOut ? `⚠ ${s.ranOut.limit === 'five_hour' ? 'session' : 'week'} ran out ${localTime(s.ranOut.at)}` : '',
        s.outsideThisMac ? (report.devices.length > 0 ? 'used outside your devices' : 'used outside this Mac') : '',
        deviceSplitText(s.devices),
      ].filter(Boolean).join(' · '),
    ]),
  ))
  lines.push('')
  lines.push(renderTable(
    [
      { header: 'Weeks · API prices' },
      { header: 'Spent', right: true },
      { header: 'Used', right: true },
      { header: 'Full week', right: true },
      { header: '' },
    ],
    report.weeks.map(w => [
      weekLabel(w),
      usd(w.spentUSD, w.unpricedModels, w.spentLowerBound),
      pct(w.usedPct, w.usedQuality),
      w.fullWeekUSD === undefined ? '–' : `${mark(w.fullWeekQuality)}$${w.fullWeekUSD.toFixed(0)}`,
      w.ranOutAt ? `⚠ ran out ${localDay(w.ranOutAt)} ${localTime(w.ranOutAt)}` : (w.endReason === 'early_reset' ? 'reset early' : w.endReason === 'moved' ? 'reset moved' : ''),
    ]),
  ))
  return lines.join('\n')
}
