# shellcheck shell=bash
set -euo pipefail

registry="$1"
github="$2"
fixture="$(mktemp -d)"
fixture="$(cd "$fixture" && pwd -P)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/repository/pkgs/fixture/npm-deps" "$fixture/archive/package/scripts"
git -C "$fixture/repository" init -q
cd "$fixture/repository/pkgs/fixture"
export PI_UPDATER_VERSION=2.0.0
export PI_UPDATER_LOCK="$fixture/new-lock.json"
export PI_UPDATER_ARCHIVE="$fixture/source.tgz"

reset_outputs() {
	printf '%s\n' '{"version":"1.0.0","tarballHash":"old"}' >source.json
	printf '%s\n' '{"original":true}' >npm-deps/package-lock.json
	printf '%s\n' '{"original":true}' >metadata.json
	cp source.json "$fixture/old-source.json"
	cp npm-deps/package-lock.json "$fixture/old-lock.json"
	cp metadata.json "$fixture/old-metadata.json"
}

make_archive() {
	printf '%s\n' '{"name":"fixture","version":"2.0.0"}' >"$fixture/archive/package/package.json"
	cp "$PI_UPDATER_LOCK" "$fixture/archive/package/package-lock.json"
	printf '%s\n' '{"release":"2.0.0"}' >"$fixture/archive/package/scripts/metadata.json"
	tar -czf "$PI_UPDATER_ARCHIVE" -C "$fixture/archive" package
}

unchanged() {
	cmp "$fixture/old-source.json" source.json
	cmp "$fixture/old-lock.json" npm-deps/package-lock.json
	cmp "$fixture/old-metadata.json" metadata.json
}

for program in "$registry" "$github"; do
	printf '%s\n' '{"lockfileVersion":3,"packages":{"":{"name":"fixture","version":"2.0.0"}}}' >"$PI_UPDATER_LOCK"
	cp "$PI_UPDATER_LOCK" "$fixture/valid-lock.json"
	make_archive
	reset_outputs
	export PI_UPDATER_FAIL_HASH=1
	if "$program"; then
		echo 'A failed hash must fail the updater' >&2
		exit 1
	fi
	unchanged
	export PI_UPDATER_FAIL_HASH=0

	for invalid in \
		'{invalid' \
		'{"lockfileVersion":"invalid","packages":{"":{"name":"fixture","version":"2.0.0"}}}' \
		'{"lockfileVersion":3,"packages":{"":{"name":"other","version":"2.0.0"}}}' \
		'{"lockfileVersion":3,"packages":{"":{"name":"fixture","version":"9.0.0"}}}'; do
		printf '%s\n' "$invalid" >"$PI_UPDATER_LOCK"
		make_archive
		if "$program"; then
			echo 'Invalid release metadata must fail the updater' >&2
			exit 1
		fi
		unchanged
	done

	cp "$fixture/valid-lock.json" "$PI_UPDATER_LOCK"
	make_archive
	"$program"
	cmp "$PI_UPDATER_LOCK" npm-deps/package-lock.json
	cmp "$fixture/archive/package/scripts/metadata.json" metadata.json
	if [[ "$program" == "$registry" ]]; then
		printf '%s\n' '{"tarballHash":"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","version":"2.0.0"}' >"$fixture/expected-source.json"
	else
		printf '%s\n' '{"hash":"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","tag":"v2.0.0","version":"2.0.0"}' >"$fixture/expected-source.json"
	fi
	jq --sort-keys . source.json >"$fixture/actual-source.json"
	jq --sort-keys . "$fixture/expected-source.json" >"$fixture/expected-source-sorted.json"
	cmp "$fixture/expected-source-sorted.json" "$fixture/actual-source.json"

	printf '%s\n' '{"lockfileVersion":3,"packages":{"":{"name":"fixture","version":"2.0.0"}},"replacement":true}' >"$PI_UPDATER_LOCK"
	make_archive
	"$program"
	cmp "$fixture/valid-lock.json" npm-deps/package-lock.json
	"$program" --force
	cmp "$PI_UPDATER_LOCK" npm-deps/package-lock.json
done
