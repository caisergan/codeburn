import { describe, expect, it } from 'vitest'

import { collectSessionMeta, compactEntry, emptySessionMeta, groupIntoTurns } from '../src/parser.js'
import type { JournalEntry } from '../src/types.js'

function user(timestamp: string, content: string, isMeta = false): JournalEntry {
  return {
    type: 'user',
    timestamp,
    sessionId: 's',
    message: { role: 'user', content },
    ...(isMeta ? { isMeta: true } : {}),
  }
}

function assistant(timestamp: string, id: string): JournalEntry {
  return {
    type: 'assistant',
    timestamp,
    sessionId: 's',
    message: {
      type: 'message',
      role: 'assistant',
      model: 'claude-opus-4-6',
      id,
      content: [],
      usage: { input_tokens: 10, output_tokens: 5 },
    },
  }
}

describe('Claude prompts followed by harness entries', () => {
  it('keeps the typed text when an image path follows it', () => {
    const turns = groupIntoTurns([
      user('2026-10-16T10:00:00Z', 'make this part nicer'),
      user('2026-10-16T10:00:01Z', '[Image: source: /tmp/shot.png]', true),
      assistant('2026-10-16T10:00:05Z', 'm1'),
    ].map(compactEntry), new Set())
    expect(turns).toHaveLength(1)
    expect(turns[0]!.userMessage).toBe('make this part nicer')
    expect(turns[0]!.timestamp).toBe('2026-10-16T10:00:00Z')
    expect(turns[0]!.assistantCalls).toHaveLength(1)
  })

  it('keeps a slash command over the skill body that follows it', () => {
    const turns = groupIntoTurns([
      user('2026-10-16T10:00:00Z', '<command-name>/review</command-name><command-args>pr 4</command-args>'),
      user('2026-10-16T10:00:01Z', 'Base directory for this skill: /skills/review', true),
      assistant('2026-10-16T10:00:05Z', 'm1'),
    ].map(compactEntry), new Set())
    expect(turns.map(t => t.userMessage)).toEqual(['<command-name>/review</command-name><command-args>pr 4</command-args>'])
  })

  it('still starts a turn on a harness entry that arrives after an answer', () => {
    const turns = groupIntoTurns([
      user('2026-10-16T10:00:00Z', 'start the agents'),
      assistant('2026-10-16T10:00:05Z', 'm1'),
      user('2026-10-16T10:01:00Z', 'Another Claude session sent a message: done', true),
      assistant('2026-10-16T10:01:05Z', 'm2'),
    ].map(compactEntry), new Set())
    expect(turns.map(t => t.userMessage)).toEqual(['start the agents', 'Another Claude session sent a message: done'])
  })
})

describe('Claude session titles', () => {
  it('prefers a /rename over Claude’s own title, whichever comes last', () => {
    const meta = emptySessionMeta()
    collectSessionMeta({ type: 'ai-title', aiTitle: 'generated' } as JournalEntry, meta)
    collectSessionMeta({ type: 'custom-title', customTitle: 'design-mobile' } as JournalEntry, meta)
    collectSessionMeta({ type: 'ai-title', aiTitle: 'generated again' } as JournalEntry, meta)
    expect(meta.title).toBe('design-mobile')
  })
})
