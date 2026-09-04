#!/usr/bin/env bash
# Month-to-date extra-usage spend for the Claude Code status line.
#
# Claude Code puts rate_limits on the status-line stdin but not extra_usage,
# so the spend is the one figure that still needs the OAuth usage API. No
# other widget needs that API, so ccstatusline makes no usage call of its own
# and this helper fetches the spend itself, caching it for a few minutes and
# backing off after a request that does not return 200.
#
# Whenever the API cannot be reached, the token is rejected, or a backoff
# window is open, the helper prints the cached spend. It prints nothing only
# when there is no cached value, and the widget then hides through
# hideWhenEmpty.

cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/ccstatusline-extra-usage"
cache="${cache_dir}/usage.json"
backoff="${cache_dir}/backoff"

ttl=180

# ccstatusline runs a custom-command widget with a one-second timeout and
# renders the literal string "[Timeout]" when the command overruns it, which
# hideWhenEmpty does not hide. Keep curl well inside that second, so a render
# that gives up prints the cached spend.
connect_timeout=0.3
max_time=0.7

now=$(date +%s)

body=""
header=""

# The status-line process is killed when a render overruns its budget, so the
# response files are removed by an exit trap, which a SIGTERM also reaches.
cleanup() {
	if [ -n "${body}" ]; then
		rm -f "${body}"
	fi

	if [ -n "${header}" ]; then
		rm -f "${header}"
	fi
}

trap cleanup EXIT
trap 'exit 143' HUP INT TERM

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

# Respect an active backoff window set after an earlier request.
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

# A curl that outlives the render keeps writing its response, so give each run
# files of its own. Sharing one header file let a survivor from an earlier
# render supply the Retry-After that this one reads.
body="$(mktemp "${cache_dir}/body.XXXXXX")"
header="$(mktemp "${cache_dir}/header.XXXXXX")"

code=$(curl -sS --connect-timeout "${connect_timeout}" --max-time "${max_time}" \
	-o "${body}" -D "${header}" -w '%{http_code}' \
	https://api.anthropic.com/api/oauth/usage \
	-H "Authorization: Bearer ${token}" \
	-H "anthropic-beta: oauth-2025-04-20" 2>/dev/null) || code=000

if [ "${code}" = "200" ]; then
	mv "${body}" "${cache}"
	body=""
	rm -f "${backoff}"

	emit
	exit 0
fi

# Every other status opens a backoff window, so an expired token or a server
# error is not re-tried on each render. A 429 names its own wait.
retry=60

if [ "${code}" = "429" ]; then
	retry=300

	server_retry=$(awk 'tolower($1) == "retry-after:" { gsub(/\r/, "", $2); print $2 }' "${header}" 2>/dev/null)
	if [ -n "${server_retry}" ]; then
		retry="${server_retry}"
	fi
fi

echo "$((now + retry))" >"${backoff}"

emit
