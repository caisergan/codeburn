# Antigravity quota while closed, and the Antigravity window warmer

Status: implemented 2026-11-28 (macOS menu bar only).

Surface: native macOS menu bar (`mac/`). The CLI (`codeburn quota`) and the
Electron app still read Antigravity quota from the local language server only.

## Quota while Antigravity is closed

Before this change, Antigravity quota came only from the running app's (or
`agy`'s) local language server, so the Plan tab said "No local Antigravity
server found" whenever the app was closed.

Now the local probe still runs first. When no local server answers, the menu
bar reads the same quota from Google:

1. **Sign-in**: the app and `agy` keep their Google sign-in in the login
   keychain, service `gemini`, account `antigravity`, as
   `go-keyring-base64:` + JSON `{token:{access_token, refresh_token, expiry},
   …}`. CodeBurn reads it with `/usr/bin/security find-generic-password -w`
   (the item's ACL already trusts `security`, so there is no prompt). It is
   never written.
2. **Token**: the stored access token while it is valid. It lasts an hour and
   nothing renews it while Antigravity is closed, so after that CodeBurn
   renews it in memory with the refresh token and Antigravity's own OAuth
   client. The client id and secret are read from the installed
   `Antigravity.app/Contents/Resources/bin/language_server` (or the `agy`
   binary): every `<digits>-<32>.apps.googleusercontent.com` id and
   `GOCSPX-<28>` secret is collected, and the pair Google accepts for the
   grant is kept for the rest of the run. Google does not rotate the refresh
   token on renewal, so this never signs the app out. Nothing is cached on
   disk.
3. **Calls** (both with `User-Agent: antigravity/<app version> darwin/<arch>`;
   without it Google answers `UNSUPPORTED_CLIENT`):
   - `POST https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
     with `{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}`
     gives the quota project and the plan (`paidTier.name`, e.g. "Google AI Pro").
   - `POST …:retrieveUserQuotaSummary` with `{"project": …}` gives the same
     groups/buckets payload the local server returns, with reset times.

No sign-in at all, or a revoked one, shows "No Antigravity sign-in found" and
asks the user to sign in to the app or `agy` once.

Code: `Data/AntigravityRemoteQuota.swift`; the fallback is in
`AntigravitySubscriptionService.refresh` (`Deps.remote`).

## The window warmer

Antigravity quota has groups ("Gemini Models", "Claude and GPT models"). The
models in a group share a weekly limit and a 5-hour limit. As with Claude, a
5-hour window starts on first use: an unused group reads 100% remaining with no
reset time, or with one that keeps sliding to "now + 5 h". Checked on
2026-11-27: after one warm, the Gemini group's reset stayed fixed at the warm
time + 5 h.

The warmer starts a group's window early, so it also resets early. It mirrors
the Claude warmer (`docs/design/claude-window-warmer.md`): a Warm button in the
Plan header, a schedule ("start a window at" times, days), and "warm again right
after each reset" with the same rules (07:00–24:00, only after a window that
read above 2%, at most 5 starts a day, here per group).

### Staying within the terms

- **The unmodified `agy` CLI sends every warm**, signed in with the user's own
  account. CodeBurn never sends a chat message with the Antigravity token and
  never calls a generate endpoint; the token is used only for the two
  read-only quota calls the app itself makes for its quota panel.
- **One short message per group, only when that group is idle.** A group with
  a running window, a used-up week or no quota reading is skipped.
- **Off by default**, for the user's own account, on this Mac only.

### The warm message

In an empty temporary directory, with `GEMINI_API_KEY`, `GOOGLE_API_KEY`,
`GOOGLE_GENAI_USE_VERTEXAI`, `GOOGLE_CLOUD_PROJECT` and
`GOOGLE_APPLICATION_CREDENTIALS` removed so `agy` uses the sign-in:

```
agy --model <cheapest model of the group> --disable-slash-commands \
    --print-timeout 90s --output-format json --print="Reply with OK."
```

The model is picked from `agy models`, matched to the group's model list, and
ranked Flash, then GPT-OSS, Haiku, Sonnet, with the lowest effort first (quota
is spent in proportion to token cost). Today that is `gemini-3.8-flash-low` for
Gemini and `gpt-oss-120b-medium` for Claude and GPT.

Cost measured 2026-11-27: one Gemini warm used about 1% of the 5-hour limit
and 0.9% of the weekly limit (about 17k input tokens of `agy` system prompt).
`agy` has no flag to skip saving the conversation, so each warm appears as a
short Antigravity conversation in CodeBurn's sessions.

### Where it runs

This Mac only, from a 60 s timer and on wake: the sign-in and `agy` live here,
and the paired VM has neither. A scheduled warm missed during sleep runs on wake
within 30 minutes; a reset missed by more than 10 minutes is not warmed late.
Settings › Antigravity › Window Warmer picks the groups (Gemini on by default)
and holds the schedule. Results (last 20) are stored in UserDefaults.

Code: `Data/AntigravityWarmer.swift` (prefs, rules, the `agy` send),
`Views/AntigravityWarmViews.swift`; the schedule rows are shared with the Claude
warmer in `Views/ClaudeWarmViews.swift`.
