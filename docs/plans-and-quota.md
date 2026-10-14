# Plans and provider quota

## Plans

```bash
codeburn plan set claude-max                                  # $200/month
codeburn plan set claude-pro                                  # $20/month
codeburn plan set cursor-pro                                  # $20/month
codeburn plan set copilot-pro                                 # 1500 AI Credits ($15 equivalent)
codeburn plan set google-ai-pro                               # $19.99/month, Antigravity usage
codeburn plan set custom --monthly-usd 200 --provider codex   # ChatGPT Pro-style custom plan
codeburn plan set custom --credits 20000 --provider copilot   # org Copilot allotment
codeburn plan reset --provider codex                          # remove one provider plan
codeburn plan set none                                        # disable plan view
codeburn plan                                                 # show configured plans
codeburn plan reset                                           # remove plan config
```

Subscription tracking for Claude Pro, Claude Max, Cursor Pro, Copilot (AI credits), and custom provider plans. Plans are stored per provider, so you can track Claude and Codex/Cursor subscriptions at the same time; the dashboard shows one overage line per active provider plan. A legacy/custom `all` plan remains a single aggregate plan and is replaced when you add a provider-specific plan, avoiding double-counted overage rows. Existing single-plan config is still read as a fallback. USD presets use publicly stated plan prices (as of April 2026). Copilot presets use official individual AI-credit allotments (Pro 1,500 / Pro+ 7,000 / Max 20,000; fetched 2026-08-23) — not the $10 / $39 / $100 sticker prices — and spend is `total_nano_aiu / 1e9`, never token-priced USD. Google presets (`google-ai-pro` $19.99, `google-ai-ultra-5x` $99.99, `google-ai-ultra-20x` $199.99; US prices fetched 2026-10-07) count Antigravity usage only, since Gemini CLI no longer signs in with these plans.

## Claude sessions and weeks

`codeburn limits` turns Claude's 5-hour and weekly windows into money and pace. For the current session, every session of the last seven days and the last four weeks it reports what was spent at API prices, how much of the 5-hour and weekly limits was used, what a full session or week is worth, and when a limit ran out.

```bash
codeburn limits               # current session, current week, sessions and weeks tables
codeburn limits --format json # the numbers the menu bar renders
```

It reads three things, all on this machine, and makes no network calls:

- the limit readings the macOS menu bar logs to `claude-limit-readings.jsonl` in the CodeBurn cache directory. While Claude is working the menu bar reads your limits every 2 minutes (5 in Low Power Mode) and for 10 minutes after, and logs failed checks with their reason;
- the refused requests Claude Code writes when a limit runs out, which give the exact minute and the exact spend at 100%;
- your local Claude calls, priced as everywhere else in CodeBurn.

Anthropic reports whole percents, so a per-session share of the week is accurate to about a point. A value marked `≈` is estimated, `≥` is a lower bound, and `–` means no reading covers it. Without the menu bar's readings the command still reports spend per session, with session times inferred from your calls, and limit-hit times. Percents include usage elsewhere (claude.ai, your phone, another Mac); dollars cover this Mac only. The full design, with how each number is measured, is in [design/claude-session-usage.md](design/claude-session-usage.md).

## Provider quota

`codeburn quota` reads how much of each provider's plan you have already spent, from the credentials the tools themselves keep on this machine. Claude, Codex, Gemini, GitHub Copilot and Kimi are read from their own signed-in sessions; Antigravity is read from its local language server.

```bash
codeburn quota               # table of every provider and its windows
codeburn quota --format json # machine-readable, pipe to jq
```

Providers you are not signed in to are listed with `available: false` and no error. Reads run in parallel with a short per-provider timeout, and the command always exits 0 so a status bar or tray can poll it safely.

```json
{
  "providers": [
    {
      "id": "claude",
      "name": "Claude",
      "available": true,
      "plan": "Max 20x",
      "windows": [{ "label": "Weekly", "usedPct": 42.5, "resetsAt": "2026-09-08T12:00:00.000Z" }]
    }
  ]
}
```

