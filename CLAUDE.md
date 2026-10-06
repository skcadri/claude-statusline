---
owner: skcadri
updated: 2026-10-05
---

# claude-statusline

- On the Mac, `~/.claude/statusline.sh` is a symlink to `~/code/claude-statusline/statusline.sh` (the main checkout, which stays on `main`). Merging to `main` changes the status line in every running Claude Code session, so run `./preview.sh` before merging. Never copy the script into `~/.claude`.
- All data comes from stdin (read once with `jq`) and local git. Never add network calls or read OAuth credentials. Claude Code cancels a run that's still going when the next refresh fires, so keep a render under ~100ms.
- The cache countdown relies on `"refreshInterval": 30` in the `statusLine` block of `~/.claude/settings.json`. Keep it there. It's what makes idle sessions re-render, and every session runs the script on that timer, which is one more reason to keep it fast.
- Always pass `--no-optional-locks` to git. Background agents commit in the same repos.
- After any change, run `./preview.sh`. When you add a new state, add a scenario for it there.
- Owner's taste calls: keep the `▰▱◆` bars, clock-time reset labels, and two lines. No pacing marker on the bars. It was removed in 324166e and again in e349aeb, so don't re-add it without asking.
- macOS only (`date -r`). The Windows desktop runs the claude-hud plugin, not this script.
