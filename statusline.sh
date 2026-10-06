#!/bin/bash

# Claude Code Status Line
# Based on https://gist.github.com/jtbr/4f99671d1cee06b44106456958caba8b
#
# Line 1: repo[/worktree][/subdir] · branch* ↑ahead ↓behind · PR · model + effort · context bar + cache countdown
# Line 2: 5-hour and weekly usage bars with reset times
#
# Everything comes from the JSON Claude Code pipes on stdin plus two local git
# calls. No network, no OAuth token.

input=$(cat)
now=$(date +%s)

R=$'\e[0m' DIM=$'\e[2m' CYAN=$'\e[96m' MAGENTA=$'\e[35m' BLUE=$'\e[94m'
GREEN=$'\e[32m' YELLOW=$'\e[33m' RED=$'\e[91m'

# stdin only carries rate_limits after a session's first API response, so a new
# or /clear'd session would show no usage line. Every session merges what it
# sees into one shared file; usage only grows within a window, so the later
# window or the higher percentage wins.
LIMITS_FILE="${CLAUDE_STATUSLINE_LIMITS:-/tmp/claude-statusline-limits.json}"

# ── Parse input (one jq call) ────────────────────────────────────────────────
eval "$(jq -r --argjson now "$now" --arg cached "$(cat "$LIMITS_FILE" 2>/dev/null)" '
  def live: if . != null and (.resets_at // 0) > $now then . else null end;
  def newer(a; b):
    if a == null then b elif b == null then a
    elif ((a.resets_at - b.resets_at) | fabs) > 600 then (if a.resets_at > b.resets_at then a else b end)
    elif a.used_percentage >= b.used_percentage then a else b end;
  def pct: if . == null then "" else floor end;

  ($cached | fromjson? // {}) as $c
  | (.rate_limits // {}) as $s
  | { five_hour: newer($s.five_hour | live; $c.five_hour | live),
      seven_day: newer($s.seven_day | live; $c.seven_day | live) } as $lim
  | .prompt_cache as $pc
  | @sh "model_name=\(.model.display_name // "Claude")",
    @sh "current_dir=\(.workspace.current_dir // .cwd // "")",
    @sh "context_pct=\(.context_window.used_percentage // 0 | floor)",
    @sh "effort=\(.effort.level // "")",
    @sh "fast_mode=\(.fast_mode // false)",
    @sh "pr_number=\(.pr.number // "")",
    @sh "pr_url=\(.pr.url // "")",
    @sh "pr_state=\(.pr.review_state // "")",
    @sh "cache_left=\(if $pc.caching_observed != true then ""
                      elif $pc.warm == true and ($pc.expires_at // 0) > $now then $pc.expires_at - $now | floor
                      else 0 end)",
    @sh "cache_ttl=\($pc.ttl // "")",
    @sh "usage_5h=\($lim.five_hour.used_percentage | pct)",
    @sh "resets_5h=\($lim.five_hour.resets_at // "")",
    @sh "usage_7d=\($lim.seven_day.used_percentage | pct)",
    @sh "resets_7d=\($lim.seven_day.resets_at // "")",
    @sh "limits_out=\(if .rate_limits then $lim | tojson else "" end)"
' <<<"$input")"

if [ -n "$limits_out" ]; then
  printf '%s' "$limits_out" > "$LIMITS_FILE.$$" && mv -f "$LIMITS_FILE.$$" "$LIMITS_FILE"
fi

# ── Location + git (rev-parse for paths, one status call for the rest) ──────
gdir="${current_dir:-$PWD}"
label=$(basename "$gdir")
wt="" wt_label="" sub_label="" git_info=""

if paths=$(git -C "$gdir" rev-parse --path-format=absolute --show-toplevel --git-common-dir --show-prefix 2>/dev/null); then
  { read -r toplevel; read -r common; read -r prefix; } <<<"$paths"

  # Name the repo after its folder (what you cd into), not the origin remote.
  if [[ "$common" == */.git ]]; then
    label=$(basename "${common%/.git}")
    [ "$common" != "$toplevel/.git" ] && wt=$(basename "$toplevel") && wt_label="/$wt"
  else
    label=$(basename "$toplevel")
  fi
  [ -n "$prefix" ] && sub_label="/${prefix%/}"

  # --no-optional-locks: don't take index.lock while background agents commit
  branch="" oid="" ahead=0 behind=0 dirty=""
  while IFS= read -r line; do
    case "$line" in
      "# branch.oid "*)  oid=${line#\# branch.oid } ;;
      "# branch.head "*) branch=${line#\# branch.head } ;;
      "# branch.ab "*)   read -r ahead behind <<<"${line#\# branch.ab }"; ahead=${ahead#+}; behind=${behind#-} ;;
      "#"*) ;;
      ?*) dirty="*" ;;
    esac
  done < <(git -C "$gdir" --no-optional-locks status --porcelain=v2 --branch --untracked-files=no 2>/dev/null)

  [ "$branch" = "(detached)" ] && branch=${oid:0:7}
  # A worktree's own branch (name or worktree-name) is already in the label.
  [ -n "$wt" ] && { [ "$branch" = "$wt" ] || [ "$branch" = "worktree-$wt" ]; } && branch=""

  git_info="${branch:+ $branch}${dirty}"
  [ "$ahead" -gt 0 ] && git_info="${git_info} ↑${ahead}"
  [ "$behind" -gt 0 ] && git_info="${git_info} ↓${behind}"
fi

# ── PR badge (clickable in iTerm2/Kitty/WezTerm via OSC 8) ───────────────────
pr_info=""
if [ -n "$pr_number" ]; then
  case "$pr_state" in
    approved)          pr_text="${GREEN}#${pr_number} ✓" ;;
    changes_requested) pr_text="${RED}#${pr_number} ✗" ;;
    draft)             pr_text="${DIM}#${pr_number} draft" ;;
    *)                 pr_text="${YELLOW}#${pr_number}" ;;
  esac
  pr_info=" "$'\e]8;;'"${pr_url}"$'\e\\'"${pr_text}"$'\e]8;;\e\\'"${R}"
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
    printf "%s" "$RED"
  elif [ "$pct" -ge 50 ]; then
    printf "%s" "$YELLOW"
  else
    printf "%s" "$DIM$GREEN"
  fi
}

# ── Model + context ──────────────────────────────────────────────────────────
model_label="${model_name}${effort:+ ${DIM}${effort}${R}}"
[ "$fast_mode" = "true" ] && model_label="${model_label} ${YELLOW}⚡${R}"

ctx_info="$(color_for_pct "$context_pct")$(make_bar "$context_pct") ${context_pct}%${R}"
# Prompt cache: time left out of its TTL (5m or 1h). Once cold, the next
# message re-processes the whole context. The countdown only ticks with
# statusLine.refreshInterval set in settings.json.
if [ -n "$cache_left" ]; then
  ttl="${cache_ttl:+/$cache_ttl}"
  case "$cache_ttl" in
    *h) ttl_s=$(( ${cache_ttl%h} * 3600 )) ;;
    *m) ttl_s=$(( ${cache_ttl%m} * 60 )) ;;
    *)  ttl_s=3600 ;;
  esac
  if [ "$cache_left" -le 0 ]; then
    ctx_info="${ctx_info} ${BLUE}cache cold${ttl}${R}"
  else
    left="$(( cache_left / 60 ))m"
    [ "$cache_left" -lt 60 ] && left="<1m"
    # Last fifth of the TTL: reply soon or it goes cold.
    color=$DIM
    [ $(( cache_left * 5 )) -le "$ttl_s" ] && color=$YELLOW
    ctx_info="${ctx_info} ${color}cache ${left}${ttl}${R}"
  fi
fi

# ── Usage segments ───────────────────────────────────────────────────────────
usage_parts=""

if [ -n "$usage_5h" ]; then
  label_5h=$(date -r "$(( (resets_5h + 1800) / 3600 * 3600 ))" '+%-l%p' | tr '[:upper:]' '[:lower:]')
  usage_parts="$(color_for_pct "$usage_5h")${label_5h} $(make_bar "$usage_5h") ${usage_5h}%${R}"
fi

if [ -n "$usage_7d" ]; then
  label_7d=$(date -r "$(( (resets_7d + 1800) / 3600 * 3600 ))" '+%a,%-l%p' | sed 's/AM$/am/;s/PM$/pm/')
  [ -n "$usage_parts" ] && usage_parts="${usage_parts}${DIM} │ ${R}"
  usage_parts="${usage_parts}$(color_for_pct "$usage_7d")${label_7d} $(make_bar "$usage_7d") ${usage_7d}%${R}"
fi

# ── Two-line output ──────────────────────────────────────────────────────────
printf '%s\n' "${DIM}${CYAN}${label}${MAGENTA}${wt_label}${CYAN}${sub_label}${R}${DIM}${git_info}${R}${pr_info}${DIM} │ ${R}${model_label}${DIM} │ ${R}${ctx_info}"
[ -n "$usage_parts" ] && printf '%s\n' "$usage_parts"
exit 0
