// The host side of the Claude window warmer: ask paired devices for their
// warm status, push the schedule to the device that runs it, and ask it to
// warm now. Only the schedule and a "warm now" request cross the link; no
// Claude credentials ever do. See docs/design/claude-window-warmer.md.

import type { WarmResult, WarmStatus } from '../claude-warm.js'
import { fetchWarmStatus, postWarmNow, putWarmSchedule, type PeerEndpoint } from './client.js'
import { loadOrCreateIdentity } from './identity.js'
import { getSharingDir, loadRemotes, type RemoteDevice } from './store.js'

/// ok: answered and accepts warm requests. not_allowed: answered but was not
/// started with --allow-warm. unsupported: a build without the warmer.
export type WarmDeviceState = 'ok' | 'not_allowed' | 'unsupported' | 'unauthorized' | 'unreachable'

export type WarmDevice = {
  id: string
  name: string
  state: WarmDeviceState
  status: WarmStatus | null
}

function stateOf(status: number): WarmDeviceState {
  if (status === 404) return 'unsupported'
  if (status === 401) return 'unauthorized'
  if (status === 403) return 'not_allowed'
  return 'unreachable'
}

async function endpointFor(remote: RemoteDevice, sharingDir: string): Promise<PeerEndpoint> {
  const identity = await loadOrCreateIdentity(sharingDir)
  return { identity, host: remote.host, port: remote.port, expectedFingerprint: remote.fingerprint }
}

/// A paired device by fingerprint or (case-insensitive) name.
export async function findRemote(target: string, sharingDir: string = getSharingDir()): Promise<RemoteDevice | null> {
  const remotes = await loadRemotes(sharingDir)
  const lower = target.toLowerCase()
  return remotes.find(r => r.fingerprint === target) ?? remotes.find(r => r.name.toLowerCase() === lower) ?? null
}

function isStatus(value: unknown): value is WarmStatus {
  return !!value && typeof value === 'object' && typeof (value as WarmStatus).allowed === 'boolean' && Array.isArray((value as WarmStatus).history)
}

export async function warmStatusOf(remote: RemoteDevice, sharingDir: string = getSharingDir()): Promise<WarmDevice> {
  const base = { id: remote.fingerprint, name: remote.name }
  try {
    const res = await fetchWarmStatus(await endpointFor(remote, sharingDir), remote.token)
    if (res.status !== 200) return { ...base, state: stateOf(res.status), status: null }
    if (!isStatus(res.json)) return { ...base, state: 'unsupported', status: null }
    return { ...base, state: res.json.allowed ? 'ok' : 'not_allowed', status: res.json }
  } catch {
    return { ...base, state: 'unreachable', status: null }
  }
}

/// Every paired device's warm status, in parallel. Never throws.
export async function listWarmDevices(sharingDir: string = getSharingDir()): Promise<WarmDevice[]> {
  const remotes = await loadRemotes(sharingDir)
  return Promise.all(remotes.map(r => warmStatusOf(r, sharingDir)))
}

export async function pushWarmSchedule(remote: RemoteDevice, schedule: unknown, sharingDir: string = getSharingDir()): Promise<{ state: WarmDeviceState; error: string | null }> {
  try {
    const res = await putWarmSchedule(await endpointFor(remote, sharingDir), remote.token, schedule)
    if (res.status === 200) return { state: 'ok', error: null }
    if (res.status === 400) return { state: 'ok', error: 'invalid schedule' }
    return { state: stateOf(res.status), error: null }
  } catch {
    return { state: 'unreachable', error: null }
  }
}

export async function warmOnDevice(remote: RemoteDevice, sharingDir: string = getSharingDir()): Promise<{ state: WarmDeviceState; result: WarmResult | null }> {
  try {
    const res = await postWarmNow(await endpointFor(remote, sharingDir), remote.token)
    if (res.status !== 200) return { state: stateOf(res.status), result: null }
    return { state: 'ok', result: res.json as WarmResult }
  } catch {
    return { state: 'unreachable', result: null }
  }
}
