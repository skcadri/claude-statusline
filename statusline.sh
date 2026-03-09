#!/bin/bash

# Claude Code Status Line — Real usage limits from Anthropic API
# Based on https://gist.github.com/jtbr/4f99671d1cee06b44106456958caba8b
#
# Shows: dir · git · cost/model · context bar · 5hr usage bar · weekly usage bar
# Usage data is fetched from the Anthropic OAuth API and cached for 60s.

input=$(cat)

# ── Parse input ──────────────────────────────────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')
model_id=$(echo "$input" | jq -r '.model.id // ""')
current_dir=$(echo "$input" | jq -r '.workspace.current_dir // ""')
context_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 10' | cut -d. -f1)

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

# ── Progress bar with diamond boundary marker ────────────────────────────────
# Usage: make_bar <pct> [width=12]
make_bar() {
  local pct=$1 width=${2:-12}
  local filled=$(( (pct * width + 50) / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width

  local bar=""
  for ((i=0; i<width; i++)); do
    if [ "$i" -eq "$filled" ] && [ "$filled" -gt 0 ] && [ "$filled" -lt "$width" ]; then
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

  # macOS: read OAuth token from Keychain
  creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || return 1

  token=$(echo "$creds" | jq -r '.claudeAiOauth.accessToken') || return 1
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

# ── Parse usage data ──────────────────────────────────────────────────────
usage_5h=""
usage_7d=""
resets_5h_label=""
resets_7d_label=""

if [ -f "$USAGE_CACHE" ]; then
  usage_5h=$(jq -r '.five_hour.utilization // empty' "$USAGE_CACHE" 2>/dev/null | cut -d. -f1)
  usage_7d=$(jq -r '.seven_day.utilization // empty' "$USAGE_CACHE" 2>/dev/null | cut -d. -f1)

  # 5-hour reset label
  resets_5h=$(jq -r '.five_hour.resets_at // empty' "$USAGE_CACHE" 2>/dev/null)
  if [ -n "$resets_5h" ]; then
    reset_epoch=$(date -juf "%Y-%m-%dT%H:%M:%S" "$(echo "$resets_5h" | cut -d. -f1 | sed 's/+.*//')" +%s 2>/dev/null)
    if [ -n "$reset_epoch" ]; then
      resets_5h_label=$(date -r "$(( (reset_epoch + 1800) / 3600 * 3600 ))" '+%-l%p' 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    fi
  fi

  # 7-day reset label
  resets_7d=$(jq -r '.seven_day.resets_at // empty' "$USAGE_CACHE" 2>/dev/null)
  if [ -n "$resets_7d" ]; then
    reset_epoch=$(date -juf "%Y-%m-%dT%H:%M:%S" "$(echo "$resets_7d" | cut -d. -f1 | sed 's/+.*//')" +%s 2>/dev/null)
    if [ -n "$reset_epoch" ]; then
      _snap=$(( (reset_epoch + 1800) / 3600 * 3600 ))
      _day=$(date -r "$_snap" '+%a' 2>/dev/null)
      _time=$(date -r "$_snap" '+%-l%p' 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d ' ')
      resets_7d_label="${_day},${_time}"
    fi
  fi
fi

# ── Build usage segments ────────────────────────────────────────────────────
usage_parts=""

if [ -n "$usage_5h" ]; then
  U5_COLOR=$(color_for_pct "$usage_5h")
  U5_BAR=$(make_bar "$usage_5h")
  usage_parts="${U5_COLOR}${resets_5h_label} ${U5_BAR} ${usage_5h}%\\033[0m"
fi

if [ -n "$usage_7d" ]; then
  U7_COLOR=$(color_for_pct "$usage_7d")
  U7_BAR=$(make_bar "$usage_7d")
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
