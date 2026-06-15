#!/usr/bin/env bash
# Render month-to-date extra-usage spend for the Claude Code status line.
#
# ccstatusline fetches the OAuth usage endpoint and caches the normalised
# response at ~/.cache/ccstatusline/usage.json whenever a usage widget is
# enabled. `extraUsageUsed` there is the spend in dollars (the API's
# extra_usage.used_credits; only extraUsageLimit is in cents). The native
# extra-usage widgets render only against a monthly limit, so they show
# nothing on an uncapped account; this reads the raw spend instead.
#
# Print nothing when extra usage is disabled, the figure is absent, or the
# cache has not been written yet, so the widget hides via hideWhenEmpty.

cache="${XDG_CACHE_HOME:-${HOME}/.cache}/ccstatusline/usage.json"
[ -r "${cache}" ] || exit 0

used=$(jq -r '
  if .extraUsageEnabled == true and .extraUsageUsed != null
  then .extraUsageUsed
  else empty
  end' "${cache}" 2>/dev/null) || exit 0

[ -n "${used}" ] || exit 0

printf '$%.2f\n' "${used}"
