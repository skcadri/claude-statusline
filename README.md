# Claude Code Statusline

A custom status line for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that shows your **real usage limits** with visual progress bars. Works on macOS and Linux.

![statusline](screenshot.png)

## What it shows

**Line 1:** Directory | Git branch | Model name + input/output pricing per 1M tokens | Context window bar

**Line 2:** 5-hour rolling usage bar with reset time | 7-day usage bar with reset time

- `▰▱` progress bars with color coding (green < 50%, yellow 50-80%, red > 80%)
- `◆` marks the edge of the fill (or, with `STATUSLINE_PACE=1`, the even-burn position — see [Options](#options))
- Each usage bar is prefixed with its reset time (`5pm`, `Sun,3pm`)

## Requirements

- macOS or Linux
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- `jq` (and `curl`, only for the OAuth fallback on older Claude Code versions)

## Install

1. Copy the script to your Claude config directory:

```bash
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

2. Add to your `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 2
  }
}
```

3. Restart Claude Code. The status line appears automatically.

## How it works

The script reads the JSON context that Claude Code pipes to status line commands. Current Claude Code versions include your 5-hour and 7-day usage in that JSON (`rate_limits`), so no network call or credentials are needed.

Older versions don't send `rate_limits`. In that case the script fetches usage from the Anthropic OAuth API (`https://api.anthropic.com/api/oauth/usage`) and caches it for 60 seconds. The OAuth token is read from `~/.claude/.credentials.json` (where newer Claude Code versions store it), falling back to the macOS Keychain for older installs.

## Options

Set these as environment variables (e.g. `"command": "STATUSLINE_PACE=1 ~/.claude/statusline.sh"`):

| Variable | Effect |
|----------|--------|
| `STATUSLINE_PACE=1` | Move each usage bar's `◆` to the even-burn position — how far through the window you are in time. If the fill runs past the `◆`, you're spending faster than the clock and will hit the limit before it resets. |

If you enable pacing, also set `"refreshInterval": 60` in the `statusLine` block so the marker moves between messages.

## Model pricing

The status line shows input/output token costs per 1M tokens for the active model:

| Model | Displayed |
|-------|-----------|
| Opus 4.6 | `$15/$75` |
| Sonnet 4.6 | `$3/$15` |
| Haiku 4.5 | `$0.8/$4` |

## Credits

Based on [jtbr's statusline gist](https://gist.github.com/jtbr/4f99671d1cee06b44106456958caba8b).

## License

MIT
