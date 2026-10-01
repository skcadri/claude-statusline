#!/bin/bash

# Claude Code Status Line — Real usage limits from Anthropic API
# Based on https://gist.github.com/jtbr/4f99671d1cee06b44106456958caba8b
#
# Shows: dir · git · cost/model · context bar · 5hr usage bar · weekly usage bar
# Usage limits come from the `rate_limits` field Claude Code pipes on stdin.
# Older Claude Code versions don't send it; then usage is fetched from the
# Anthropic OAuth API and cached for 60s.
#
# Works on macOS (BSD date/stat) and Linux (GNU coreutils).
#
# Options (env vars):
#   STATUSLINE_PACE=1  put the ◆ at the even-burn position for each usage
#                      window instead of at the fill edge — fill running past
#                      the ◆ means you're spending faster than the clock.

input=$(cat)
now=$(date +%s)

# ── Parse input ──────────────────────────────────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')
model_id=$(echo "$input" | jq -r '.model.id // ""')
current_dir=$(echo "$input" | jq -r '.workspace.current_dir // ""')
context_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 10' | cut -d. -f1)
stdin_5h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' | cut -d. -f1)
stdin_5h_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
stdin_7d=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' | cut -d. -f1)
stdin_7d_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# Model input/output pricing per 1M tokens
case "$model_id" in
  *opus-4*)   model_price="\$15/\$75" ;;
  *sonnet-4*) model_price="\$3/\$15"  ;;
  *haiku-4*)  model_price="\$0.8/\$4" ;;
  *)          model_price=""           ;;
esac

if [ -n "$current_dir" ]; then
  dir_name=$(basename "$current_dir")
else
  dir_name=$(basename "$(pwd)")
fi

# ── Git info ─────────────────────────────────────────────────────────────────
git_info=""
if [ -n "$current_dir" ]; then
  branch=$(git -C "$current_dir" branch --show-current 2>/dev/null || git -C "$current_dir" rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    if ! git -C "$current_dir" diff --quiet 2>/dev/null || ! git -C "$current_dir" diff --cached --quiet 2>/dev/null; then
      git_info=" ${branch}*"
    else
      git_info=" ${branch}"
    fi
  fi
elif git rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git branch --show-current 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
      git_info=" ${branch}*"
    else
      git_info=" ${branch}"
    fi
  fi
fi

# ── Portable date/stat (GNU coreutils on Linux, BSD on macOS) ───────────────
if date --version >/dev/null 2>&1; then
  date_parse_iso() { date -d "$1" +%s 2>/dev/null; }
  date_fmt()       { date -d "@$1" "$2" 2>/dev/null; }
  file_mtime()     { stat -c %Y "$1" 2>/dev/null; }
else
  date_parse_iso() { date -juf "%Y-%m-%dT%H:%M:%S" "$(echo "$1" | cut -d. -f1 | sed 's/+.*//')" +%s 2>/dev/null; }
  date_fmt()       { date -r "$1" "$2" 2>/dev/null; }
  file_mtime()     { stat -f %m "$1" 2>/dev/null; }
fi

# epoch_of <resets_at> — stdin sends epoch seconds, the OAuth API sends RFC 3339
epoch_of() {
  case "$1" in
    ''|*[!0-9.]*) date_parse_iso "$1" ;;
    *)            echo "${1%%.*}" ;;
  esac
}

# pace_pct <reset_epoch> <window_seconds> — how far through the window we are
pace_pct() {
  local p=$(( (now - $1 + $2) * 100 / $2 ))
  [ "$p" -lt 0 ] && p=0; [ "$p" -gt 100 ] && p=100
  echo "$p"
}

# ── Progress bar with diamond marker ─────────────────────────────────────────
# Usage: make_bar <pct> [pace_pct] [width=12]
#   Without pace_pct the ◆ marks the fill edge; with it, the even-burn position.
make_bar() {
  local pct=$1 pace=$2 width=${3:-12}
  local filled=$(( (pct * width + 50) / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width

  local marker=-1
  if [ -n "$pace" ]; then
    marker=$(( pace * width / 100 ))
    [ "$marker" -ge "$width" ] && marker=$((width - 1))
  elif [ "$filled" -gt 0 ] && [ "$filled" -lt "$width" ]; then
    marker=$filled
  fi

  local bar=""
  for ((i=0; i<width; i++)); do
    if [ "$i" -eq "$marker" ]; then
      bar="${bar}◆"
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
CTX_BAR=$(make_bar "$context_pct")

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

# ── Usage data: stdin first, OAuth API fallback ─────────────────────────────
usage_5h="$stdin_5h"
usage_7d="$stdin_7d"
resets_5h="$stdin_5h_reset"
resets_7d="$stdin_7d_reset"

if [ -z "$usage_5h" ] && [ -z "$usage_7d" ]; then
  # Refresh cache if stale or missing
  if [ ! -f "$USAGE_CACHE" ] || [ $(( now - $(file_mtime "$USAGE_CACHE" || echo 0) )) -gt $USAGE_CACHE_AGE ]; then
    fetch_usage 2>/dev/null
  fi

  if [ -f "$USAGE_CACHE" ]; then
    usage_5h=$(jq -r '.five_hour.utilization // empty' "$USAGE_CACHE" 2>/dev/null | cut -d. -f1)
    usage_7d=$(jq -r '.seven_day.utilization // empty' "$USAGE_CACHE" 2>/dev/null | cut -d. -f1)
    resets_5h=$(jq -r '.five_hour.resets_at // empty' "$USAGE_CACHE" 2>/dev/null)
    resets_7d=$(jq -r '.seven_day.resets_at // empty' "$USAGE_CACHE" 2>/dev/null)
  fi
fi

# ── Reset labels (and pacing, when enabled) ─────────────────────────────────
resets_5h_label=""
resets_7d_label=""
pace_5h=""
pace_7d=""

# 5-hour reset label
if [ -n "$resets_5h" ]; then
  reset_epoch=$(epoch_of "$resets_5h")
  if [ -n "$reset_epoch" ]; then
    resets_5h_label=$(date_fmt "$(( (reset_epoch + 1800) / 3600 * 3600 ))" '+%-l%p' | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    [ "$STATUSLINE_PACE" = 1 ] && pace_5h=$(pace_pct "$reset_epoch" 18000)
  fi
fi

# 7-day reset label
if [ -n "$resets_7d" ]; then
  reset_epoch=$(epoch_of "$resets_7d")
  if [ -n "$reset_epoch" ]; then
    _snap=$(( (reset_epoch + 1800) / 3600 * 3600 ))
    _day=$(date_fmt "$_snap" '+%a')
    _time=$(date_fmt "$_snap" '+%-l%p' | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    resets_7d_label="${_day},${_time}"
    [ "$STATUSLINE_PACE" = 1 ] && pace_7d=$(pace_pct "$reset_epoch" 604800)
  fi
fi

# ── Build usage segments ────────────────────────────────────────────────────
usage_parts=""

if [ -n "$usage_5h" ]; then
  U5_COLOR=$(color_for_pct "$usage_5h")
  U5_BAR=$(make_bar "$usage_5h" "$pace_5h")
  usage_parts="${U5_COLOR}${resets_5h_label} ${U5_BAR} ${usage_5h}%\\033[0m"
fi

if [ -n "$usage_7d" ]; then
  U7_COLOR=$(color_for_pct "$usage_7d")
  U7_BAR=$(make_bar "$usage_7d" "$pace_7d")
  [ -n "$usage_parts" ] && usage_parts="${usage_parts}\\033[2m │ \\033[0m"
  usage_parts="${usage_parts}${U7_COLOR}${resets_7d_label} ${U7_BAR} ${usage_7d}%\\033[0m"
fi

# ── Build model label (name + pricing if known) ─────────────────────────────
if [ -n "$model_price" ]; then
  model_label="${model_name} \\033[2m${model_price}\\033[0m"
else
  model_label="${model_name}"
fi

# ── Two-line output ──────────────────────────────────────────────────────────
# Line 1: dir · git · model (pricing) · context bar
echo -e "\\033[2m\\033[96m${dir_name}\\033[0m\\033[2m${git_info} │ \\033[0m${model_label}\\033[2m │ \\033[0m${CTX_COLOR}${CTX_BAR} ${context_pct}%\\033[0m"

# Line 2: 5hr and weekly usage bars (only if data available)
if [ -n "$usage_parts" ]; then
  echo -e "$usage_parts"
fi
