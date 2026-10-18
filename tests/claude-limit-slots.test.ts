import { mkdtemp, mkdir, rm, writeFile } from 'fs/promises'
import { tmpdir } from 'os'
import { join } from 'path'

import { afterAll, beforeAll, describe, expect, it } from 'vitest'

import { aggregateLimitSlots, readClaudeAccountHash } from '../src/claude-limit-sources.js'
import type { LimitCall } from '../src/claude-limits.js'

const t = (s: string): number => Date.parse(s)

function call(at: string, costUSD: number, model = 'claude-opus-5-5', chatId = 'chat-a'): LimitCall {
  return {
    at: t(at),
    costUSD,
    tokens: { input: 1, output: 2, cacheRead: 3, cacheWrite: 4 },
    model,
    modelName: model,
    unpriced: false,
    chatId,
    chatTitle: 'a secret project title',
    chatProject: 'secret-project',
    chatPath: '/Users/me/secret-project',
  }
}

describe('slots a paired device sends', () => {
  it('sum calls per 10-minute slot and model, with the first and last call times', () => {
    const slots = aggregateLimitSlots([
      call('2026-10-15T03:09:59Z', 1),
      call('2026-10-15T03:10:00Z', 2),
      call('2026-10-15T03:12:00Z', 3, 'claude-opus-5-5', 'chat-b'),
      call('2026-10-15T03:19:30Z', 4),
      call('2026-10-15T03:15:00Z', 5, 'claude-fable-5-1'),
    ])
    expect(slots.map(s => [new Date(s.at).toISOString(), s.model, s.costUSD, new Date(s.firstAt).toISOString(), new Date(s.lastAt).toISOString()])).toEqual([
      ['2026-10-15T03:00:00.000Z', 'claude-opus-5-5', 1, '2026-10-15T03:09:59.000Z', '2026-10-15T03:09:59.000Z'],
      ['2026-10-15T03:10:00.000Z', 'claude-fable-5-1', 5, '2026-10-15T03:15:00.000Z', '2026-10-15T03:15:00.000Z'],
      ['2026-10-15T03:10:00.000Z', 'claude-opus-5-5', 9, '2026-10-15T03:10:00.000Z', '2026-10-15T03:19:30.000Z'],
    ])
    expect(slots[2]!.tokens).toEqual({ input: 3, output: 6, cacheRead: 9, cacheWrite: 12 })
  })

  it('carry no chat, title, project or path', () => {
    const [slot] = aggregateLimitSlots([call('2026-10-15T03:10:00Z', 2)])
    expect(JSON.stringify(slot)).not.toMatch(/secret|chat-a/)
  })

  it('never re-send spend that came from another device', () => {
    const relayed = { ...call('2026-10-15T03:10:00Z', 2), device: { id: 'fp', name: 'vm' } }
    expect(aggregateLimitSlots([relayed])).toEqual([])
  })
})

describe('the Claude account hash', () => {
  let home: string

  beforeAll(async () => {
    home = await mkdtemp(join(tmpdir(), 'codeburn-account-'))
  })

  afterAll(async () => {
    await rm(home, { recursive: true, force: true })
  })

  it('hashes the account id of the default directory from ~/.claude.json', async () => {
    await writeFile(join(home, '.claude.json'), JSON.stringify({ oauthAccount: { accountUuid: 'uuid-1', emailAddress: 'me@example.com' } }))
    const hash = await readClaudeAccountHash(join(home, '.claude'), home)
    expect(hash).toMatch(/^[a-f0-9]{64}$/)
    expect(hash).not.toContain('uuid-1')
    expect(await readClaudeAccountHash(undefined, home)).toBe(hash)
  })

  it('reads a CLAUDE_CONFIG_DIR’s own file, never falling back to the default one', async () => {
    const custom = join(home, 'work-claude')
    await mkdir(custom, { recursive: true })
    expect(await readClaudeAccountHash(custom, home)).toBeNull()
    await writeFile(join(custom, '.claude.json'), JSON.stringify({ oauthAccount: { accountUuid: 'uuid-2' } }))
    const work = await readClaudeAccountHash(custom, home)
    expect(work).not.toBeNull()
    expect(work).not.toBe(await readClaudeAccountHash(undefined, home))
  })

  it('is null for an API-key login', async () => {
    const other = await mkdtemp(join(tmpdir(), 'codeburn-account-'))
    await writeFile(join(other, '.claude.json'), JSON.stringify({ primaryApiKey: 'x' }))
    expect(await readClaudeAccountHash(undefined, other)).toBeNull()
    await rm(other, { recursive: true, force: true })
  })
})
