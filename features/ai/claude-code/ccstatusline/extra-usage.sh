#!/usr/bin/env bash
# Month-to-date extra-usage spend for the Claude Code status line.
#
# Claude Code exposes rate_limits on the status-line stdin but not extra_usage,
# so the spend is the one figure that still needs the OAuth usage API. No other
# widget needs that API, so ccstatusline makes no usage call of its own; this
# helper fetches the spend directly, caches it for a few minutes, and backs off
# on HTTP 429 for the server's Retry-After. It prints nothing on any error or
# while backing off (showing the last known value if one is cached), so the
# widget hides via hideWhenEmpty when there is nothing to show.

cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/ccstatusline-extra-usage"
cache="${cache_dir}/usage.json"
backoff="${cache_dir}/backoff"
header="${cache_dir}/headers"

ttl=180

now=$(date +%s)

emit() {
	local used

	used=$(jq -r '
    if .extra_usage.is_enabled == true and .extra_usage.used_credits != null
    then .extra_usage.used_credits
    else empty
    end' "${cache}" 2>/dev/null) || return 0

	[ -n "${used}" ] || return 0

	# used_credits is in cents.
	awk -v cents="${used}" 'BEGIN { printf "$%.2f\n", cents / 100 }'
}

file_mtime() {
	stat -c %Y "$1" 2>/dev/null || echo 0
}

# Read the OAuth token the way Claude Code stores it: the macOS Keychain on
# Darwin, the plaintext credentials file elsewhere (and as a Darwin fallback).
read_token() {
	local t=""

	if [ "$(uname -s)" = "Darwin" ]; then
		t=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null |
			jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null) || t=""
	fi

	if [ -z "${t}" ]; then
		t=$(jq -r '.claudeAiOauth.accessToken // empty' \
			"${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/.credentials.json" 2>/dev/null) || t=""
	fi

	printf '%s' "${t}"
}

# Serve a fresh cache without calling the API.
if [ -r "${cache}" ] && [ "$((now - $(file_mtime "${cache}")))" -lt "${ttl}" ]; then
	emit
	exit 0
fi

# Respect an active backoff window set after a previous 429.
if [ -r "${backoff}" ] && [ "${now}" -lt "$(cat "${backoff}" 2>/dev/null || echo 0)" ]; then
	emit
	exit 0
fi

token=$(read_token)

[ -n "${token}" ] || {
	emit
	exit 0
}

mkdir -p "${cache_dir}"

tmp=$(mktemp)

code=$(curl -sS --max-time 5 -o "${tmp}" -D "${header}" -w '%{http_code}' \
	https://api.anthropic.com/api/oauth/usage \
	-H "Authorization: Bearer ${token}" \
	-H "anthropic-beta: oauth-2025-04-20" 2>/dev/null) || code=000

if [ "${code}" = "200" ]; then
	mv "${tmp}" "${cache}"
	rm -f "${backoff}"

	emit
	exit 0
fi

rm -f "${tmp}"

# A 429 sets a backoff window from the server's Retry-After.
if [ "${code}" = "429" ]; then
	retry=$(awk 'tolower($1) == "retry-after:" { gsub(/\r/, "", $2); print $2 }' "${header}" 2>/dev/null)
	[ -n "${retry}" ] || retry=300

	echo "$((now + retry))" >"${backoff}"
fi

# Any non-200: fall back to the last known value if we have one, else nothing.
emit
