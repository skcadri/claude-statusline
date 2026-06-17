# Claude Code Statusline

A custom status line for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that shows **real usage limits** from the Anthropic API with visual progress bars.

![statusline](screenshot.png)

## What it shows

**Line 1:** Directory | Git branch | Model name | Context window bar

**Line 2:** `5h` rolling usage bar with reset time | `wk` 7-day usage bar with reset time

- `▰▱` progress bars with color coding (green < 50%, yellow 50-80%, red > 80%)
- `◇` pacing marker shows where you'd be at an even burn rate across the window — if the fill runs **past** the `◇`, you're spending faster than the clock
- `⟳` followed by the reset time for each window
- Bars are labeled (`ctx` / `5h` / `wk`) and percentages are bolded so your eye lands on the number that matters

## Requirements

- macOS (reads OAuth credentials from `~/.claude/.credentials.json`, Keychain fallback)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- `jq` and `curl`

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

The script reads the JSON context that Claude Code pipes to status line commands, then fetches your actual usage data from the Anthropic OAuth API (`https://api.anthropic.com/api/oauth/usage`). Results are cached for 60 seconds to avoid excessive API calls.

The OAuth token is read from `~/.claude/.credentials.json` (where newer Claude Code versions store it), falling back to the macOS Keychain for older installs.

## Credits

Based on [jtbr's statusline gist](https://gist.github.com/jtbr/4f99671d1cee06b44106456958caba8b).

## License

MIT
