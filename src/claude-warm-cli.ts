// `codeburn warm`: the Claude window warmer from the command line and for the
// menu bar app. See docs/design/claude-window-warmer.md.

import { hostname } from 'os'

import { buildWarmStatus, runWarm, setWarmSchedule, type WarmResult, type WarmStatus } from './claude-warm.js'
import { findRemote, listWarmDevices, pushWarmSchedule, warmOnDevice, warmStatusOf } from './sharing/claude-warm-peers.js'

export type WarmCommandOptions = {
  device?: string
  devices?: boolean
  set?: string
  force?: boolean
  scheduled?: boolean
  format: 'text' | 'json'
}

function fail(message: string): never {
  process.stderr.write(`codeburn warm: ${message}\n`)
  process.exit(1)
}

function out(format: 'text' | 'json', json: unknown, text: string): void {
  process.stdout.write(format === 'json' ? `${JSON.stringify(json)}\n` : `${text}\n`)
}

const clock = (iso: string | null): string => (iso ? new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '?')

export function describeResult(result: WarmResult): string {
  switch (result.reason) {
    case null:
      return result.resetsAt ? `Started a 5-hour window; it resets at ${clock(result.resetsAt)}.` : 'Sent the warm message.'
    case 'window_running':
      return `Skipped: a 5-hour window is already running${result.resetsAt ? ` (resets ${clock(result.resetsAt)})` : ''}.`
    case 'weekly_full':
      return 'Skipped: the weekly limit is used up, so a new window could not be used.'
    case 'usage_unavailable':
      return 'Skipped: could not read Claude usage, so it is unknown whether a window is running.'
    case 'claude_not_found':
      return 'Failed: the `claude` CLI was not found on this machine.'
    case 'send_failed':
      return `Failed: Claude Code did not answer${result.detail ? ` (${result.detail})` : ''}.`
    case 'no_window_yet':
      return 'Claude answered, but the new window is not showing in usage yet.'
  }
}

function describeStatus(status: WarmStatus | null): string {
  const schedule = status?.schedule
  if (!schedule) return ''
  let text = ` · schedule ${schedule.enabled ? 'on' : 'off'} ${schedule.times.join(', ')}`
  // A version-1 device has no auto-warm; its schedule comes back without it.
  if (schedule.auto) {
    text += ` · auto-warm ${schedule.auto.enabled ? `on ${schedule.auto.from}–${schedule.auto.to}` : 'off'}`
    const window = status.currentWindow
    if (schedule.auto.enabled && window) {
      text += ` · window resets ${clock(window.resetsAt)}, highest ${Math.round(window.maxPercent * 100)}%`
    }
  }
  return text
}

export async function runWarmCommand(action: string | undefined, opts: WarmCommandOptions): Promise<void> {
  const remote = opts.device ? await findRemote(opts.device) : null
  if (opts.device && !remote) fail(`no paired device named "${opts.device}". See \`codeburn devices\`.`)
  const runner = remote ? { id: remote.fingerprint, name: remote.name, local: false } : { id: 'local', name: hostname(), local: true }

  if (action === 'status') {
    if (remote) {
      const device = await warmStatusOf(remote)
      out(opts.format, device, `${device.name}: ${device.state}${describeStatus(device.status)}`)
      return
    }
    const local = await buildWarmStatus({ allowed: true })
    const devices = opts.devices ? await listWarmDevices() : []
    const lines = [
      `This machine: claude ${local.claudeFound ? 'found' : 'not found'}${describeStatus(local)}`,
      ...devices.map(d => `${d.name}: ${d.state}${describeStatus(d.status)}`),
      ...local.history.slice(0, 5).map(r => `  ${new Date(r.at).toLocaleString()} ${r.trigger}: ${describeResult(r)}`),
    ]
    out(opts.format, { local, devices }, lines.join('\n'))
    return
  }

  if (action === 'schedule') {
    if (!opts.set) fail('schedule needs --set <json>.')
    let parsed: unknown
    try {
      parsed = JSON.parse(opts.set)
    } catch {
      fail('--set is not valid JSON.')
    }
    if (remote) {
      const pushed = await pushWarmSchedule(remote, parsed)
      if (pushed.error) fail(pushed.error)
      out(opts.format, { runner, state: pushed.state }, `${remote.name}: ${pushed.state}`)
      return
    }
    const schedule = await setWarmSchedule(parsed)
    if (!schedule) fail('invalid schedule: needs enabled, times ("HH:MM", at most 4), days (0 = Monday … 6 = Sunday), a valid timeZone and optionally auto ({ enabled, from: "HH:MM", to: "HH:MM" or "24:00" }).')
    out(opts.format, { runner, state: 'ok', schedule }, `Schedule saved: ${schedule.enabled ? 'on' : 'off'} ${schedule.times.join(', ')} · auto-warm ${schedule.auto.enabled ? 'on' : 'off'}`)
    return
  }

  if (action !== undefined) fail('unknown action. Valid values: status, schedule (or none to warm now).')

  // A warm can take over a minute; keep the app's no-output watchdog fed.
  const { startProgressKeepalive, stopProgressKeepalive } = await import('./parser.js')
  startProgressKeepalive()
  try {
    if (remote) {
      const { state, result } = await warmOnDevice(remote)
      out(opts.format, { runner, state, result }, result ? `${remote.name}: ${describeResult(result)}` : `${remote.name}: ${state}`)
      return
    }
    const result = await runWarm({ trigger: opts.scheduled ? 'scheduled' : 'manual', force: !!opts.force })
    out(opts.format, { runner, state: 'ok', result }, describeResult(result))
  } finally {
    stopProgressKeepalive()
  }
}
