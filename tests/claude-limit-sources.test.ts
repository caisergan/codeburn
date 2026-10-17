import { appendFile, mkdir, mkdtemp, rm, writeFile } from 'fs/promises'
import { tmpdir } from 'os'
import { join } from 'path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import { cleanPrompt, clearLimitEventsMemo, collectLimitCalls, collectLimitEvents, collectLimitPrompts, parseLimitEventLine, parseReadingLine, readReadingLog } from '../src/claude-limit-sources.js'
import type { ProjectSummary, SessionSummary, TokenUsage } from '../src/types.js'

// The shape Claude Code writes for a request refused at a limit (text trimmed).
function refusal(timestamp: string, rateLimitType: string, resetsAtSeconds: number, status = 'rejected'): string {
  return JSON.stringify({
    parentUuid: 'p', isSidechain: false, type: 'assistant', uuid: 'u', timestamp,
    message: {
      id: 'm', model: '<synthetic>', role: 'assistant', stop_reason: 'stop_sequence', type: 'message',
      usage: { input_tokens: 0, output_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
      content: [{ type: 'text', text: 'You\'ve hit your session limit · resets 6pm' }],
    },
    requestId: 'req_1',
    quotaLimits: {
      status, resetsAt: resetsAtSeconds, unifiedRateLimitFallbackAvailable: false, rateLimitType,
      overageStatus: 'rejected', overageDisabledReason: 'org_level_disabled', upgradePaths: ['upgrade_plan'], isUsingOverage: false,
    },
    error: 'rate_limit', isApiErrorMessage: true, apiErrorStatus: 429, sessionId: 's1',
  })
}

describe('parseLimitEventLine', () => {
  it('reads the limit, the refusal time and the reset time in epoch seconds', () => {
    expect(parseLimitEventLine(refusal('2026-10-04T14:32:59.709Z', 'five_hour', 1791126000))).toEqual({
      limit: 'five_hour',
      at: Date.parse('2026-10-04T14:32:59.709Z'),
      resetsAt: 1791126000 * 1000,
    })
  })

  it('ignores allowed requests, other limit types and unrelated lines', () => {
    expect(parseLimitEventLine(refusal('2026-10-04T14:32:59Z', 'five_hour', 1791126000, 'allowed'))).toBeNull()
    expect(parseLimitEventLine(refusal('2026-10-04T14:32:59Z', 'seven_day_opus', 1791126000))).toBeNull()
    expect(parseLimitEventLine('{"type":"user","message":{"content":"what is quotaLimits?"}}')).toBeNull()
    expect(parseLimitEventLine('{"quotaLimits": torn')).toBeNull()
  })
})

describe('reading log', () => {
  let dir: string
  beforeEach(async () => { dir = await mkdtemp(join(tmpdir(), 'cb-limits-')) })
  afterEach(async () => { await rm(dir, { recursive: true, force: true }) })

  it('parses readings and failed checks and skips malformed lines', async () => {
    const path = join(dir, 'claude-limit-readings.jsonl')
    await writeFile(path, [
      '{"at":"2026-10-14T11:26:04Z","ok":true,"plan":"Max 5x","five_hour":{"pct":58,"resetsAt":"2026-10-14T12:59:59.622Z"},"seven_day":{"pct":8,"resetsAt":"2026-10-21T07:59:59.622Z"},"scoped":[{"label":"Weekly · Fable","pct":0,"resetsAt":"2026-10-21T08:00:00Z"}]}',
      '{"at":"2026-10-14T11:28:04Z","ok":false,"reason":"rate_limited","retryAfter":300}',
      '{"at":"2026-10-14T11:30:04Z","ok":true,"imported":true,"seven_day":{"pct":9,"resetsAt":"2026-10-21T08:00:00Z"}}',
      'not json',
      '{"at":"2026-10-14T11:32:04Z","ok":tr',
    ].join('\n'))
    const log = await readReadingLog(path)
    expect(log.readings).toHaveLength(2)
    expect(log.readings[0]).toEqual({
      at: Date.parse('2026-10-14T11:26:04Z'),
      plan: 'Max 5x',
      fiveHour: { pct: 58, resetsAt: Date.parse('2026-10-14T12:59:59.622Z') },
      sevenDay: { pct: 8, resetsAt: Date.parse('2026-10-21T07:59:59.622Z') },
    })
    expect(log.readings[1]!.imported).toBe(true)
    expect(log.failures).toEqual([{ at: Date.parse('2026-10-14T11:28:04Z'), reason: 'rate_limited', retryAfter: 300 }])
  })

  it('returns nothing when the menubar has not written the log', async () => {
    expect(await readReadingLog(join(dir, 'missing.jsonl'))).toEqual({ readings: [], failures: [] })
  })

  it('rejects a reading without a time', () => {
    expect(parseReadingLine('{"ok":true}')).toBeNull()
  })
})

describe('collectLimitEvents', () => {
  let root: string
  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), 'cb-limit-events-'))
    clearLimitEventsMemo()
  })
  afterEach(async () => { await rm(root, { recursive: true, force: true }) })

  it('scans transcripts and subagent transcripts incrementally, holding back a line still being written', async () => {
    const claude = join(root, 'claude')
    const cache = join(root, 'cache')
    const project = join(claude, 'projects', '-Users-me-app')
    await mkdir(join(project, 's1', 'subagents'), { recursive: true })
    const main = join(project, 's1.jsonl')
    const sub = join(project, 's1', 'subagents', 'agent-1.jsonl')
    await writeFile(main, '{"type":"user"}\n' + refusal('2026-10-04T14:32:59Z', 'five_hour', 1791126000) + '\n')
    await writeFile(sub, refusal('2026-10-04T14:40:00Z', 'seven_day', 1791200000) + '\n')

    const since = Date.parse('2026-01-01T00:00:00Z')
    const first = await collectLimitEvents([claude], since, cache)
    expect(first.map(e => e.limit).sort()).toEqual(['five_hour', 'seven_day'])

    // A refusal half-written at EOF is not read until its newline lands.
    const line = refusal('2026-10-04T15:00:00Z', 'five_hour', 1791126000)
    await appendFile(main, line.slice(0, 40))
    clearLimitEventsMemo()
    expect(await collectLimitEvents([claude], since, cache)).toHaveLength(2)
    await appendFile(main, line.slice(40) + '\n')
    // Within the memo window a resident process answers from memory.
    expect(await collectLimitEvents([claude], since, cache)).toHaveLength(2)
    clearLimitEventsMemo()
    const third = await collectLimitEvents([claude], since, cache)
    expect(third).toHaveLength(3)

    // A rewritten (shorter) file is read from the start again.
    await writeFile(main, '{"type":"user"}\n')
    clearLimitEventsMemo()
    const fourth = await collectLimitEvents([claude], since, cache)
    expect(fourth.map(e => e.limit)).toEqual(['seven_day'])
  })

  it('drops events older than the window', async () => {
    const claude = join(root, 'claude')
    const project = join(claude, 'projects', 'p')
    await mkdir(project, { recursive: true })
    await writeFile(join(project, 'a.jsonl'), refusal('2026-01-04T14:32:59Z', 'five_hour', 1791126000) + '\n')
    expect(await collectLimitEvents([claude], Date.parse('2026-06-01T00:00:00Z') - 365 * 86400e3, join(root, 'c'))).toHaveLength(1)
    clearLimitEventsMemo()
    expect(await collectLimitEvents([claude], Date.parse('2026-06-01T00:00:00Z'), join(root, 'c'))).toHaveLength(0)
  })
})

const ZERO: TokenUsage = {
  inputTokens: 0, outputTokens: 0, cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
  cachedInputTokens: 0, reasoningTokens: 0, webSearchRequests: 0,
}

function session(sessionId: string, opts: Partial<SessionSummary> & { calls: Array<[string, number]>; prompt?: string }): SessionSummary {
  return {
    sessionId,
    project: 'app',
    firstTimestamp: opts.calls[0]![0],
    lastTimestamp: opts.calls.at(-1)![0],
    totalCostUSD: 0, totalSavingsUSD: 0, totalInputTokens: 0, totalOutputTokens: 0, totalReasoningTokens: 0,
    totalCacheReadTokens: 0, totalCacheWriteTokens: 0, apiCalls: opts.calls.length,
    turns: [{
      userMessage: opts.prompt ?? '',
      timestamp: opts.calls[0]![0],
      sessionId,
      category: 'coding', retries: 0, hasEdits: false,
      assistantCalls: opts.calls.map(([timestamp, costUSD]) => ({
        provider: 'claude', model: 'claude-opus-4-6', usage: { ...ZERO, inputTokens: 5, outputTokens: 7, cacheReadInputTokens: 100, cacheCreationInputTokens: 3 },
        costUSD, tools: [], mcpTools: [], skills: [], subagentTypes: [], hasAgentSpawn: false, hasPlanMode: false,
        speed: 'standard', timestamp, bashCommands: [], deduplicationKey: `${sessionId}:${timestamp}`,
      })),
    }],
    modelBreakdown: {}, toolBreakdown: {}, mcpBreakdown: {}, bashBreakdown: {},
    categoryBreakdown: {} as SessionSummary['categoryBreakdown'], skillBreakdown: {}, subagentBreakdown: {},
    ...opts,
  } as SessionSummary
}

describe('collectLimitCalls', () => {
  it('titles chats and folds subagents into their parent', () => {
    const projects: ProjectSummary[] = [{
      project: '-Users-me-api-server', projectPath: '/Users/me/api-server', totalCostUSD: 0, totalSavingsUSD: 0, totalApiCalls: 0, totalProxiedCostUSD: 0,
      sessions: [
        session('parent', { calls: [['2026-10-14T10:00:00Z', 2]], prompt: 'refactor the auth flow\nplease' }),
        session('child', { calls: [['2026-10-14T10:05:00Z', 3]], isSidechain: true, parentSessionId: 'parent' }),
        session('titled', { calls: [['2026-10-14T10:06:00Z', 1]], title: 'Release notes' }),
      ],
    }]
    const calls = collectLimitCalls(projects)
    expect(calls.map(c => [c.chatId, c.chatTitle, c.chatProject, c.costUSD])).toEqual([
      ['parent', 'refactor the auth flow please', 'api-server', 2],
      ['parent', 'refactor the auth flow please', 'api-server', 3],
      ['titled', 'Release notes', 'api-server', 1],
    ])
    expect(calls[0]!.chatPath).toBe('/Users/me/api-server')
    expect(calls[0]!.tokens).toEqual({ input: 5, output: 7, cacheRead: 100, cacheWrite: 3 })
  })

  it('keeps only the default account when several Claude directories are configured', () => {
    const projects: ProjectSummary[] = [{
      project: 'p', projectPath: '/p', totalCostUSD: 0, totalSavingsUSD: 0, totalApiCalls: 0, totalProxiedCostUSD: 0,
      sessions: [
        session('mine', { calls: [['2026-10-14T10:00:00Z', 2]], source: { id: 'a', label: 'Default Claude', path: '/home/me/.claude', kind: 'claude-config' } }),
        session('work', { calls: [['2026-10-14T10:00:00Z', 9]], source: { id: 'b', label: 'work', path: '/home/me/.claude-work', kind: 'claude-config' } }),
      ],
    }]
    expect(collectLimitCalls(projects, '/home/me/.claude').map(c => c.chatId)).toEqual(['mine'])
  })

  it('names a chat after Monocode first, then its own title, then its first real prompt', () => {
    const projects: ProjectSummary[] = [{
      project: 'p', projectPath: '/Users/me/web', totalCostUSD: 0, totalSavingsUSD: 0, totalApiCalls: 0, totalProxiedCostUSD: 0,
      sessions: [
        session('mono', { calls: [['2026-10-14T10:00:00Z', 2]], title: 'Claude’s name', prompt: 'hello' }),
        session('own', { calls: [['2026-10-14T10:01:00Z', 2]], title: 'Release notes', prompt: 'hello' }),
        session('img', { calls: [['2026-10-14T10:02:00Z', 2]], prompt: '[Image: source: /tmp/a.png] fix the header' }),
        session('bare', { calls: [['2026-10-14T10:03:00Z', 2]], prompt: '<task-notification>done</task-notification>' }),
      ],
    }]
    const titles = new Map([['mono', 'Toptan teslim bakiyesi']])
    expect(collectLimitCalls(projects, undefined, titles).map(c => c.chatTitle)).toEqual([
      'Toptan teslim bakiyesi', 'Release notes', 'fix the header', 'web',
    ])
  })

  it('collects the prompts the user typed, oldest first, without machine text', () => {
    const projects: ProjectSummary[] = [{
      project: 'p', projectPath: '/Users/me/web', totalCostUSD: 0, totalSavingsUSD: 0, totalApiCalls: 0, totalProxiedCostUSD: 0,
      sessions: [
        session('b', { calls: [['2026-10-14T10:05:00Z', 1]], prompt: 'second chat' }),
        session('a', { calls: [['2026-10-14T10:00:00Z', 1]], prompt: 'token=abcdefghijklmnop please' }),
        session('child', { calls: [['2026-10-14T10:01:00Z', 1]], isSidechain: true, parentSessionId: 'a', prompt: 'subagent brief' }),
        session('c', { calls: [['2026-10-14T10:06:00Z', 1]], prompt: '[Request interrupted by user]' }),
      ],
    }]
    expect(collectLimitPrompts(projects).map(p => [p.chatId, p.text])).toEqual([
      ['a', 'token=•••• please'],
      ['b', 'second chat'],
    ])
  })
})

describe('cleanPrompt', () => {
  it('keeps what the user typed and drops what tools wrapped around it', () => {
    expect(cleanPrompt('[Image: source: /private/tmp/x.png]\n[Image #2] make it nicer')).toBe('make it nicer')
    expect(cleanPrompt('You are continuing an existing conversation handed off from Claude Code. Not new.\n\nŞu kısmı güzelleştirelim\n\nPrior conversation from Claude Code:\n<handoff>…')).toBe('Şu kısmı güzelleştirelim')
    expect(cleanPrompt('<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>pr 4</command-args>')).toBe('/review pr 4')
    expect(cleanPrompt('fix it <system-reminder>be careful</system-reminder> now')).toBe('fix it now')
    expect(cleanPrompt('<task-notification><task-id>x</task-id></task-notification>')).toBe('')
    expect(cleanPrompt('Base directory for this skill: /skills/x\n# Skill')).toBe('')
    expect(cleanPrompt('Caveat: The messages below were generated by the user while running local commands.')).toBe('')
  })
})
