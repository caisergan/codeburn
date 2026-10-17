import { mkdtemp, rm } from 'fs/promises'
import { createRequire } from 'module'
import { tmpdir } from 'os'
import { join } from 'path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'

import { monocodeDatabasePath, monocodeTitle, readMonocodeTitles } from '../src/monocode-titles.js'
import { isSqliteAvailable } from '../src/sqlite.js'

const requireForTest = createRequire(import.meta.url)

describe('monocodeTitle', () => {
  it('strips the harness prefix and skips chats Monocode has not named', () => {
    expect(monocodeTitle('claude · Fix the parser', 'claude')).toBe('Fix the parser')
    expect(monocodeTitle('Renamed by hand', 'claude')).toBe('Renamed by hand')
    expect(monocodeTitle('claude', 'claude')).toBeNull()
    expect(monocodeTitle('  ', 'claude')).toBeNull()
  })
})

describe('monocodeDatabasePath', () => {
  it('follows the app data folder of each platform, or the override', () => {
    expect(monocodeDatabasePath({}, 'darwin', '/Users/me')).toBe('/Users/me/Library/Application Support/com.monocode.desktop/monocode.db')
    expect(monocodeDatabasePath({}, 'linux', '/home/me')).toBe('/home/me/.local/share/com.monocode.desktop/monocode.db')
    expect(monocodeDatabasePath({ CODEBURN_MONOCODE_DB: '/x.db' }, 'darwin', '/Users/me')).toBe('/x.db')
  })
})

const withSqlite = isSqliteAvailable() ? describe : describe.skip

withSqlite('readMonocodeTitles', () => {
  let dir: string
  beforeAll(async () => {
    dir = await mkdtemp(join(tmpdir(), 'codeburn-monocode-'))
  })
  afterAll(async () => {
    await rm(dir, { recursive: true, force: true })
  })

  it('maps Claude session ids to Monocode’s names, newest row winning', () => {
    const path = join(dir, 'monocode.db')
    const { DatabaseSync } = requireForTest('node:sqlite')
    const db = new DatabaseSync(path)
    db.exec(`CREATE TABLE sessions (id TEXT PRIMARY KEY, harness TEXT NOT NULL, title TEXT NOT NULL,
             provider_session_id TEXT, updated_at INTEGER NOT NULL)`)
    const insert = db.prepare('INSERT INTO sessions VALUES (?, ?, ?, ?, ?)')
    insert.run('1', 'claude', 'claude · Old name', 'abc', 1)
    insert.run('2', 'claude', 'claude · New name', 'abc', 2)
    insert.run('3', 'claude', 'claude', 'unnamed', 3)
    insert.run('4', 'codex', 'codex · Not Claude', 'xyz', 4)
    insert.run('5', 'claude', 'claude · No provider id', null, 5)
    db.close()
    expect([...readMonocodeTitles(path)]).toEqual([['abc', 'New name']])
  })

  it('is empty when Monocode is not installed or its database has another shape', () => {
    expect(readMonocodeTitles(join(dir, 'missing.db')).size).toBe(0)
    const path = join(dir, 'other.db')
    const { DatabaseSync } = requireForTest('node:sqlite')
    const db = new DatabaseSync(path)
    db.exec('CREATE TABLE notes (id TEXT)')
    db.close()
    expect(readMonocodeTitles(path).size).toBe(0)
  })
})
