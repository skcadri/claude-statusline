#!/bin/bash

# Claude Code Status Line — Real usage limits from Anthropic API
# Based on https://gist.github.com/jtbr/4f99671d1cee06b44106456958caba8b
#
# Shows: dir · git · model · context bar · 5h usage bar · weekly usage bar
# Each usage bar carries a ◇ pacing marker (where you'd be at an even burn
# rate); if the fill runs past the ◇ you're spending faster than the clock.
# Usage data is fetched from the Anthropic OAuth API and cached for 60s.

input=$(cat)
now=$(date +%s)

# ── Parse input ──────────────────────────────────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')
current_dir=$(echo "$input" | jq -r '.workspace.current_dir // ""')
context_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 10' | cut -d. -f1)

if [ -n "$current_dir" ]; then
  dir_name=$(basename "$current_dir")
else
  dir_name=$(basename "$(pwd)")
fi

# ── Git info ─────────────────────────────────────────────────────────────────
branch=""
dirty=""
gdir="${current_dir:-$(pwd)}"
branch=$(git -C "$gdir" branch --show-current 2>/dev/null || git -C "$gdir" rev-parse --short HEAD 2>/dev/null)
if [ -n "$branch" ]; then
  if ! git -C "$gdir" diff --quiet 2>/dev/null || ! git -C "$gdir" diff --cached --quiet 2>/dev/null; then
    dirty="*"
  fi
fi

branch_seg=""
if [ -n "$branch" ]; then
  branch_seg="  \\033[2m\\033[35m⎇ ${branch}${dirty}\\033[0m"
fi

# ── Progress bar with fill + pacing marker ───────────────────────────────────
# make_bar <fill_pct> <pace_pct|""> [width=12]
#   ▰ used   ▱ remaining   ◇ pacing marker (even-burn position)
make_bar() {
  local pct=$1 pace=$2 width=${3:-12}
  local filled=$(( (pct * width + 50) / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width

  local pacei=-1
  if [ -n "$pace" ]; then
    pacei=$(( (pace * width + 50) / 100 ))
    [ "$pacei" -ge "$width" ] && pacei=$((width - 1))
    [ "$pacei" -lt 0 ] && pacei=0
  fi

  local bar=""
  for ((i=0; i<width; i++)); do
    if [ "$i" -eq "$pacei" ]; then
      bar="${bar}◇"
    elif [ "$i" -lt "$filled" ]; then
      bar="${bar}▰"
    else
      bar="${bar}▱"
    fi
  done
  printf "%s" "$bar"
}

color_for_pct() {
  local pct=$1
  if [ "$pct" -ge 80 ]; then
    printf "\\033[91m"         # bright red
  elif [ "$pct" -ge 50 ]; then
    printf "\\033[33m"         # yellow
  else
    printf "\\033[2m\\033[32m" # dim green
  fi
}

CTX_COLOR=$(color_for_pct "$context_pct")
CTX_BAR=$(make_bar "$context_pct" "")

# ── Fetch real usage from Anthropic API ──────────────────────────────────────
USAGE_CACHE="/tmp/claude-statusline-usage.json"
USAGE_CACHE_AGE=60

fetch_usage() {
  local creds token response

  # Prefer file-based credentials (~/.claude/.credentials.json); newer Claude
  # Code versions store the OAuth token here instead of the macOS Keychain.
  if [ -f ~/.claude/.credentials.json ]; then
    token=$(jq -r '.claudeAiOauth.accessToken // empty' ~/.claude/.credentials.json 2>/dev/null)
  fi

  # Fall back to the macOS Keychain if no file token was found.
  if [ -z "$token" ] || [ "$token" = "null" ]; then
    creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    token=$(echo "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  fi

  [ -z "$token" ] || [ "$token" = "null" ] && return 1

  response=$(curl -s --max-time 3 "https://api.anthropic.com/api/oauth/usage" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "Content-Type: application/json" 2>/dev/null) || return 1

  if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
    return 1
  fi

  echo "$response" > "$USAGE_CACHE"
}

# Refresh cache if stale or missing (macOS stat uses -f%m)
if [ ! -f "$USAGE_CACHE" ] || [ $(($(date +%s) - $(stat -f%m "$USAGE_CACHE" 2>/dev/null || echo 0))) -gt $USAGE_CACHE_AGE ]; then
  fetch_usage 2>/dev/null
fi

# ── Parse usage data ─────────────────────────────────────────────────────────
usage_5h=""; usage_7d=""
pace_5h=""; pace_7d=""
resets_5h_label=""; resets_7d_label=""

# epoch_of <iso8601> — parse the API's RFC3339 timestamp to epoch seconds
epoch_of() {
  date -juf "%Y-%m-%dT%H:%M:%S" "$(echo "$1" | cut -d. -f1 | sed 's/+.*//')" +%s 2>/dev/null
}
# pace_pct <reset_epoch> <window_seconds> — how far through the window we are
pace_pct() {
  local p=$(( (now - $1 + $2) * 100 / $2 ))
  [ "$p" -lt 0 ] && p=0; [ "$p" -gt 100 ] && p=100
  echo "$p"
}

if [ -f "$USAGE_CACHE" ]; then
  usage_5h=$(jq -r '.five_hour.utilization // empty' "$USAGE_CACHE" 2>/dev/null | cut -d. -f1)
  usage_7d=$(jq -r '.seven_day.utilization // empty' "$USAGE_CACHE" 2>/dev/null | cut -d. -f1)

  # 5-hour reset + pace (window = 5h = 18000s)
  resets_5h=$(jq -r '.five_hour.resets_at // empty' "$USAGE_CACHE" 2>/dev/null)
  if [ -n "$resets_5h" ]; then
    reset_epoch=$(epoch_of "$resets_5h")
    if [ -n "$reset_epoch" ]; then
      resets_5h_label=$(date -r "$(( (reset_epoch + 1800) / 3600 * 3600 ))" '+%-l%p' 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d ' ')
      pace_5h=$(pace_pct "$reset_epoch" 18000)
    fi
  fi

  # 7-day reset + pace (window = 7d = 604800s)
  resets_7d=$(jq -r '.seven_day.resets_at // empty' "$USAGE_CACHE" 2>/dev/null)
  if [ -n "$resets_7d" ]; then
    reset_epoch=$(epoch_of "$resets_7d")
    if [ -n "$reset_epoch" ]; then
      _snap=$(( (reset_epoch + 1800) / 3600 * 3600 ))
      _day=$(date -r "$_snap" '+%a' 2>/dev/null)
      _time=$(date -r "$_snap" '+%-l%p' 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d ' ')
      resets_7d_label="${_day} ${_time}"
      pace_7d=$(pace_pct "$reset_epoch" 604800)
    fi
  fi
fi

# ── Build usage line (labeled, with reset times) ─────────────────────────────
usage_parts=""

if [ -n "$usage_5h" ]; then
  U5_COLOR=$(color_for_pct "$usage_5h")
  U5_BAR=$(make_bar "$usage_5h" "$pace_5h")
  usage_parts="\\033[2m\\033[37m5h\\033[0m ${U5_COLOR}${U5_BAR}\\033[0m \\033[1m${usage_5h}%\\033[0m\\033[2m ⟳${resets_5h_label}\\033[0m"
fi

if [ -n "$usage_7d" ]; then
  U7_COLOR=$(color_for_pct "$usage_7d")
  U7_BAR=$(make_bar "$usage_7d" "$pace_7d")
  [ -n "$usage_parts" ] && usage_parts="${usage_parts}\\033[2m     \\033[0m"
  usage_parts="${usage_parts}\\033[2m\\033[37mwk\\033[0m ${U7_COLOR}${U7_BAR}\\033[0m \\033[1m${usage_7d}%\\033[0m\\033[2m ⟳${resets_7d_label}\\033[0m"
fi

# ── Two-line output ──────────────────────────────────────────────────────────
# Line 1: dir · git · model · context bar
echo -e "\\033[96m${dir_name}\\033[0m${branch_seg}\\033[2m   \\033[0m\\033[1m\\033[97m${model_name}\\033[0m\\033[2m   \\033[0m\\033[2mctx\\033[0m ${CTX_COLOR}${CTX_BAR}\\033[0m \\033[1m${context_pct}%\\033[0m"

# Line 2: 5h and weekly usage bars (only if data available)
if [ -n "$usage_parts" ]; then
  echo -e "$usage_parts"
fi
