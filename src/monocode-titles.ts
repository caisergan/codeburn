// Chat names from Monocode, a desktop app that runs Claude Code chats through
// the SDK. Claude Code writes no `ai-title` for SDK-driven chats, so without
// these they would be named after their first message. Monocode keeps its own
// title for each chat, keyed by the Claude session id, in a SQLite database
// that is only ever read here.

import { statSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

import { isSqliteAvailable, openDatabase } from './sqlite.js'

const APP_ID = 'com.monocode.desktop'

export function monocodeDatabasePath(
  env: NodeJS.ProcessEnv = process.env,
  platform: NodeJS.Platform = process.platform,
  home = homedir(),
): string {
  if (env['CODEBURN_MONOCODE_DB']) return env['CODEBURN_MONOCODE_DB']
  if (platform === 'darwin') return join(home, 'Library', 'Application Support', APP_ID, 'monocode.db')
  if (platform === 'win32') return join(env['APPDATA'] ?? join(home, 'AppData', 'Roaming'), APP_ID, 'monocode.db')
  return join(env['XDG_DATA_HOME'] ?? join(home, '.local', 'share'), APP_ID, 'monocode.db')
}

/// Monocode stores "claude · Fix the parser", and the bare harness name until
/// it has named the chat. A title the user renamed carries no prefix.
export function monocodeTitle(raw: string, harness: string): string | null {
  const title = raw.trim()
  const prefix = `${harness} · `
  const stripped = title.startsWith(prefix) ? title.slice(prefix.length).trim() : title
  if (!stripped || stripped === harness) return null
  return stripped
}

type Memo = { path: string; stamp: string; titles: Map<string, string> }
let memo: Memo | null = null

/// Claude session id → Monocode's title for it. Empty when Monocode is not
/// installed, SQLite is unavailable, or the database cannot be read.
export function readMonocodeTitles(path = monocodeDatabasePath()): Map<string, string> {
  let stamp: string
  try {
    // The database and its write-ahead log: a rename lands in the log first.
    const db = statSync(path)
    let wal = 0
    try { wal = statSync(`${path}-wal`).mtimeMs } catch {}
    stamp = `${db.mtimeMs}:${db.size}:${wal}`
  } catch {
    return new Map()
  }
  if (memo && memo.path === path && memo.stamp === stamp) return memo.titles
  if (!isSqliteAvailable()) return new Map()

  const titles = new Map<string, string>()
  let db: ReturnType<typeof openDatabase> | undefined
  try {
    db = openDatabase(path)
    // Oldest first, so a session id Monocode re-used keeps its newest title.
    const rows = db.query<{ id: unknown; title: unknown; harness: unknown }>(
      `SELECT provider_session_id AS id, title, harness FROM sessions
       WHERE provider_session_id IS NOT NULL AND harness = 'claude'
       ORDER BY updated_at`,
    )
    for (const row of rows) {
      if (typeof row.id !== 'string' || typeof row.title !== 'string' || typeof row.harness !== 'string') continue
      const title = monocodeTitle(row.title, row.harness)
      if (title) titles.set(row.id, title)
    }
  } catch {
    return new Map()
  } finally {
    try { db?.close() } catch {}
  }
  memo = { path, stamp, titles }
  return titles
}
