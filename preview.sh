#!/bin/bash
# Render the status line for each state it can be in, against a throwaway git
# repo, without touching your real usage cache. Run: ./preview.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export CLAUDE_STATUSLINE_LIMITS="$tmp/limits.json"
now=$(date +%s)

# Repo "demo": main pushed to an origin, plus a worktree one commit ahead with
# an uncommitted edit — the shape Claude's background jobs leave behind.
g() { git -C "$tmp/$1" -c user.name=preview -c user.email=preview@example.com "${@:2}"; }
git init -q --bare "$tmp/origin.git"
git init -q -b main "$tmp/demo"
mkdir "$tmp/demo/src" && echo a > "$tmp/demo/src/a"
g demo add . && g demo commit -qm init
g demo remote add origin "$tmp/origin.git" && g demo push -q -u origin main 2>/dev/null
g demo worktree add -q -b worktree-fix-login .claude/worktrees/fix-login origin/main 2>/dev/null
wt=demo/.claude/worktrees/fix-login
echo b > "$tmp/$wt/src/a" && g $wt commit -qam "fix login"
echo c >> "$tmp/$wt/src/a"

# render <title> <jq filter applied to the base input>
render() {
  echo "── $1"
  jq -n --arg dir "$tmp/demo" --argjson now "$now" '{
    model: {id: "claude-opus-5-5", display_name: "Opus 5.5"},
    workspace: {current_dir: $dir}, effort: {level: "xhigh"}, fast_mode: false
  } | '"$2" | "$here/statusline.sh"
  echo
}

render "new session (no API response yet, no shared cache)" '.'

render "mid-session on main" '
  .context_window.used_percentage = 37.4
  | .prompt_cache = {caching_observed: true, warm: true, expires_at: ($now + 2400)}
  | .rate_limits = {five_hour: {used_percentage: 7.0, resets_at: ($now + 10800)},
                    seven_day: {used_percentage: 23.0, resets_at: ($now + 345600)}}'

render "new session in another tab (usage comes from the shared cache)" '.'

render "worktree, PR approved, heavy usage, fast mode, cache gone cold" '
  .workspace.current_dir = $dir + "/.claude/worktrees/fix-login"
  | .pr = {number: 42, url: "https://github.com/acme/demo/pull/42", review_state: "approved"}
  | .fast_mode = true
  | .context_window.used_percentage = 82
  | .prompt_cache = {caching_observed: true, warm: false, expires_at: ($now - 60)}
  | .rate_limits = {five_hour: {used_percentage: 86.2, resets_at: ($now + 10800)},
                    seven_day: {used_percentage: 63.0, resets_at: ($now + 345600)}}'

render "subdirectory, PR changes requested, idle tab's stale 50% loses to 86%" '
  .workspace.current_dir = $dir + "/src"
  | .pr = {number: 43, url: "https://github.com/acme/demo/pull/43", review_state: "changes_requested"}
  | .context_window.used_percentage = 55
  | .rate_limits = {five_hour: {used_percentage: 50.0, resets_at: ($now + 10800)}}'

render "outside git, model without effort" '
  .workspace.current_dir = "/tmp" | del(.effort) | .model.display_name = "Haiku 4.5"'
