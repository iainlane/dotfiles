#!/usr/bin/env bash
# Print a rolling-limit usage percentage for the Claude Code status line, read
# from the rate_limits block Claude Code provides on stdin.
#
# Claude Code passes rate_limits in the status-line JSON (five_hour, seven_day,
# ...), each carrying used_percentage and resets_at. Reading it here needs no
# OAuth usage API call, so it never trips the usage rate limit. A plan without
# the window omits the bucket (used_percentage null/absent), so the helper
# emits nothing and the widget hides via hideWhenEmpty.
#
# Usage: ccstatusline-usage-pct <rate-limits-bucket> <label>

bucket=$1
label=$2

pct=$(jq -r --arg bucket "${bucket}" '
  if (.rate_limits[$bucket].used_percentage) == null then empty
  else .rate_limits[$bucket].used_percentage
  end' 2>/dev/null) || exit 0

[ -n "${pct}" ] || exit 0

awk -v label="${label}" -v pct="${pct}" 'BEGIN { printf "%s %.1f%%\n", label, pct }'
