#!/usr/bin/env bash

# Runs backup.sh with stub `curl` and `r2` commands, and checks which HTTP
# requests the script makes and which files it passes to `r2 backup`.

set -euo pipefail

backup_script="${1}"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

mkdir "${test_dir}/bin"

# The Nix build sandbox has no /usr/bin/env, so give the stubs the running
# bash as their interpreter.
stub() {
	printf '#!%s\n' "${BASH}" >"${test_dir}/bin/${1}"
	cat >>"${test_dir}/bin/${1}"
	chmod +x "${test_dir}/bin/${1}"
}

# Records each request: the config read from stdin and then the arguments,
# one per line. Answers the backup command with the canned response and
# writes the canned file for a download.
stub curl <<'EOF'

set -euo pipefail

{
	echo "--- request"
	cat
	printf '%s\n' "$@"
} >>"${FAKE_CURL_LOG}"

output=""
url=""

while [ "$#" -gt 0 ]; do
	case "${1}" in
	--output)
		output="${2}"
		shift
		;;

	http*)
		url="${1}"
		;;
	esac

	shift
done

case "${url}" in
*/cmd/backup)
	cat "${FAKE_COMMAND_RESPONSE}"
	;;

*/dl/backup/*)
	cp "${FAKE_BACKUP_FILE}" "${output}"
	;;

*)
	echo "unexpected request: ${url}" >&2
	exit 22
	;;
esac
EOF

# Lists what it was given to archive, with sizes.
stub r2 <<'EOF'

set -euo pipefail

[ "${1}" = backup ] || {
	echo "expected 'r2 backup', got 'r2 ${*}'" >&2
	exit 1
}

for path in "${BACKUP_SOURCE}"/*; do
	printf '%s %s\n' "${path##*/}" "$(stat -c %s "${path}")"
done >"${FAKE_R2_LOG}"
EOF

run_backup() {
	PATH="${test_dir}/bin:${PATH}" \
		TMPDIR="${test_dir}/scratch" \
		FAKE_CURL_LOG="${test_dir}/curl.log" \
		FAKE_R2_LOG="${test_dir}/r2.log" \
		FAKE_COMMAND_RESPONSE="${test_dir}/${1}.json" \
		FAKE_BACKUP_FILE="${test_dir}/${2}.unf" \
		UNIFI_URL=https://192.0.2.1:11443 \
		UNIFI_SITE=default \
		UNIFI_STATISTICS_DAYS="${statistics_days:-0}" \
		UNIFI_API_KEY=hunter2 \
		bash "${backup_script}"
}

report_failure() {
	local scenario="${1}" detail="${2}"

	{
		echo "scenario: ${scenario}"
		echo "${detail}"

		if [ -f "${test_dir}/curl.log" ]; then
			echo "requests:"
			cat "${test_dir}/curl.log"
		fi
	} >&2

	exit 1
}

# Runs one scenario and checks its exit status and output. `expected_status`
# is `zero` when the script has to accept the controller and `nonzero` when it
# has to refuse the response.
assert_backup() {
	local scenario="${1}" expected_status="${2}" expected="${3}" output status

	rm -rf "${test_dir}/curl.log" "${test_dir}/r2.log" "${test_dir}/scratch"
	mkdir "${test_dir}/scratch"

	set +e
	output="$(run_backup "${scenario}" "${4:-real}" 2>&1)"
	status=$?
	set -e

	case "${expected_status}" in
	zero)
		[[ "${status}" -eq 0 ]] ||
			report_failure "${scenario}" "expected success, got status ${status}: ${output}"
		;;

	nonzero)
		[[ "${status}" -ne 0 ]] ||
			report_failure "${scenario}" "expected failure, got success: ${output}"
		;;
	esac

	[[ "${output}" == *"${expected}"* ]] ||
		report_failure "${scenario}" "expected output to contain '${expected}', got: ${output}"
}

assert_file_equals() {
	local scenario="${1}" actual="${2}" expected="${3}"

	diff -u <(printf '%s' "${expected}") "${actual}" ||
		report_failure "${scenario}" "${actual##*/} differs from what was expected"
}

printf 'UBNT backup bytes\n' >"${test_dir}/real.unf"
: >"${test_dir}/empty.unf"

echo '{"meta":{"rc":"ok"},"data":[{"url":"/dl/backup/10.6.101.unf"}]}' >"${test_dir}/ok.json"
echo '{"meta":{"rc":"ok"},"data":[]}' >"${test_dir}/no-url.json"
echo '{"meta":{"rc":"error","msg":"api.err.Invalid"}}' >"${test_dir}/error.json"

# The whole exchange: the command names the site and the days of statistics,
# the download fetches the URL returned by the controller, under the Network
# application's prefix, and the key travels in the config on stdin, never on
# the command line. The script's working directory is the only one under the
# scratch TMPDIR, so its path is known.
assert_backup ok zero "downloaded 10.6.101.unf: 18 bytes"

work_dir="$(find "${test_dir}/scratch" -mindepth 1 -maxdepth 1 -type d)"

assert_file_equals ok "${test_dir}/curl.log" '--- request
header = "X-API-KEY: hunter2"
--config
-
--silent
--show-error
--fail
--insecure
--request
POST
--header
Content-Type: application/json
--data
{"cmd":"backup","days":0}
https://192.0.2.1:11443/proxy/network/api/s/default/cmd/backup
--- request
header = "X-API-KEY: hunter2"
--config
-
--silent
--show-error
--fail
--insecure
--output
'"${work_dir}"'/snapshot/10.6.101.unf
https://192.0.2.1:11443/proxy/network/dl/backup/10.6.101.unf
'

assert_file_equals ok "${test_dir}/r2.log" '10.6.101.unf 18
'

# The days setting reaches the command unchanged, including the -1 that asks
# for the whole history.
statistics_days=-1 assert_backup ok zero "downloaded 10.6.101.unf: 18 bytes"
grep -q '{"cmd":"backup","days":-1}' "${test_dir}/curl.log" ||
	report_failure "all history" "the command did not ask for days=-1"

# A response without a URL, whether the command failed or the shape changed,
# stops the run before anything is uploaded.
assert_backup no-url nonzero "no backup URL"
[ ! -f "${test_dir}/r2.log" ] || report_failure no-url "r2 was run"

assert_backup error nonzero "no backup URL"
[ ! -f "${test_dir}/r2.log" ] || report_failure error "r2 was run"

# A download that completes with no bytes would upload an empty archive.
assert_backup ok nonzero "10.6.101.unf is empty" empty
[ ! -f "${test_dir}/r2.log" ] || report_failure empty "r2 was run"
