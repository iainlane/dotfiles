# shellcheck shell=bash
set -euo pipefail

registry="$1"
github="$2"
patched_registry="$3"
patched_github="$4"
invalid_registry="$5"
invalid_github="$6"
fixture="$(mktemp -d)"
fixture="$(cd "$fixture" && pwd -P)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/repository/pkgs/fixture/npm-deps" "$fixture/archive/package/scripts"
git -C "$fixture/repository" init -q
cd "$fixture/repository/pkgs/fixture"
export PI_UPDATER_VERSION=2.0.0
export PI_UPDATER_LOCK="$fixture/new-lock.json"
export PI_UPDATER_ARCHIVE="$fixture/source.tgz"
export PI_UPDATER_URL="$fixture/url"

reset_outputs() {
	printf '%s\n' '{"version":"1.0.0","tarballHash":"old"}' >source.json
	printf '%s\n' '{"original":true}' >npm-deps/package-lock.json
	printf '%s\n' '{"original":true}' >metadata.json
	cp source.json "$fixture/old-source.json"
	cp npm-deps/package-lock.json "$fixture/old-lock.json"
	cp metadata.json "$fixture/old-metadata.json"
}

# Package the release with `$PI_UPDATER_LOCK` as the lockfile named by the
# second argument, or with no lockfile when it is `none`.
make_archive() {
	local manifest='{"name":"fixture","version":"2.0.0"}' lockfile="${2:-package-lock.json}"
	printf '%s\n' "${1:-$manifest}" >"$fixture/archive/package/package.json"
	rm -f "$fixture/archive/package/"{package-lock.json,npm-shrinkwrap.json,yarn.lock}
	if [[ "$lockfile" != none ]]; then
		cp "$PI_UPDATER_LOCK" "$fixture/archive/package/$lockfile"
	fi
	printf '%s\n' before >"$fixture/archive/package/support.txt"
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
	if [[ "$program" == "$github" ]]; then
		jq '.rev = "explicit-revision"' source.json >"$fixture/pinned-source.json"
		cp "$fixture/pinned-source.json" source.json
	fi
	cp source.json "$fixture/pinned-source.json"
	PI_UPDATER_FORBID_DISCOVERY=1 "$program" --refresh
	cmp "$fixture/pinned-source.json" source.json
	cmp "$PI_UPDATER_LOCK" npm-deps/package-lock.json
	if [[ "$program" == "$github" ]]; then
		grep -Fx 'https://github.com/fixture/fixture/archive/explicit-revision.tar.gz' "$PI_UPDATER_URL"
	fi

	printf '%s\n' '{"lockfileVersion":3,"packages":{"":{"name":"fixture","version":"2.0.0","dependencies":{"dep":"1.0.0"}},"node_modules/dep":{"version":"1.0.0","dependencies":{"shared":"^2.0.0"}},"node_modules/shared":{"version":"1.0.0"}}}' >"$PI_UPDATER_LOCK"
	make_archive '{"name":"fixture","version":"2.0.0","dependencies":{"dep":"1.0.0"}}'
	reset_outputs
	if "$program"; then
		echo 'A lockfile that does not satisfy its manifest must fail the updater' >&2
		exit 1
	fi
	unchanged

	make_archive '{"name":"fixture","version":"2.0.0","dependencies":{"dep":"1.0.0"},"overrides":{"shared":"1.0.0"}}'
	"$program"
	jq '.packages[""].overrides = {"shared": "1.0.0"}' "$PI_UPDATER_LOCK" >"$fixture/expected-lock.json"
	cmp "$fixture/expected-lock.json" npm-deps/package-lock.json
done

# Package a release whose lockfile, named by the optional second argument,
# differs from npm's newest resolution, and record the release in
# `source.json`.
prepare_maintenance() {
	printf '%s\n' '{"lockfileVersion":3,"packages":{"":{"name":"fixture","version":"2.0.0"}},"resolution":"release"}' >"$PI_UPDATER_LOCK"
	make_archive '' "${2:-package-lock.json}"
	printf '%s\n' '{"lockfileVersion":3,"packages":{"":{"name":"fixture","version":"2.0.0"}},"resolution":"newest"}' >"$PI_UPDATER_LOCK"
	reset_outputs
	if [[ "$1" == "$registry" ]]; then
		printf '%s\n' '{"tarballHash":"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","version":"2.0.0"}' >source.json
	else
		printf '%s\n' '{"hash":"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","tag":"v2.0.0","version":"2.0.0"}' >source.json
	fi
	cp source.json "$fixture/maintained-source.json"
}

for lockfile in package-lock.json npm-shrinkwrap.json yarn.lock; do
	for program in "$registry" "$github"; do
		prepare_maintenance "$program" "$lockfile"

		PI_UPDATER_FORBID_DISCOVERY=1 "$program" --maintain-lockfile
		cmp "$fixture/maintained-source.json" source.json
		cmp "$PI_UPDATER_LOCK" npm-deps/package-lock.json
	done
done

mkdir "$fixture/home"
for npmrc in "$fixture/archive/package/.npmrc" "$fixture/home/.npmrc" "$fixture/global-npmrc"; do
	printf '%s\n' 'registry=https://elsewhere.invalid/' '@fixture:registry=https://elsewhere.invalid/' >"$npmrc"
done
for program in "$registry" "$github"; do
	prepare_maintenance "$program"

	HOME="$fixture/home" PI_UPDATER_GLOBAL_NPMRC="$fixture/global-npmrc" PI_UPDATER_FORBID_DISCOVERY=1 \
		"$program" --maintain-lockfile
	cmp "$fixture/maintained-source.json" source.json
	cmp "$PI_UPDATER_LOCK" npm-deps/package-lock.json
done
rm "$fixture/archive/package/.npmrc"

printf '%s\n' '{"lockfileVersion":3,"packages":{"":{"name":"fixture","version":"2.0.0"},"node_modules/runtime":{"version":"1.0.0"}}}' >"$PI_UPDATER_LOCK"
make_archive '' none
jq --compact-output '.packages[""] += {"peerDependencies":{"host":"^1.4.0"},"dependencies":{"runtime":"1.0.0"}}' "$PI_UPDATER_LOCK" >"$fixture/expected-lock.json"
for program in "$patched_registry" "$patched_github"; do
	reset_outputs
	"$program"
	cmp "$fixture/expected-lock.json" npm-deps/package-lock.json
done

make_archive
for program in "$invalid_registry" "$invalid_github"; do
	reset_outputs
	if "$program"; then
		echo 'A failed source patch must fail the updater' >&2
		exit 1
	fi
	unchanged
done
upstream="$fixture/upstream"
git init -q -b main "$upstream"
git -C "$upstream" config uploadpack.allowReachableSHA1InWant true
git -C "$upstream" config uploadpack.allowFilter true

commit() {
	git -C "$upstream" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m "$1"
	git -C "$upstream" rev-parse HEAD
}

base="$(commit base)"
pinned="$(commit pinned)"
released="$(commit released)"
git -C "$upstream" switch -q -c unrelated "$base"
unrelated="$(commit unrelated)"

export PI_UPDATER_GIT_REMOTE="$upstream"
export PI_UPDATER_REPOSITORY='{"type":"git","url":"git+https://github.com/fixture/fixture.git","directory":"packages/fixture"}'
export PI_UPDATER_GIT_HEAD="$unrelated"

make_commit_archive() {
	local root="$fixture/commit-archive/fixture-$pinned"

	rm -rf "$fixture/commit-archive"
	mkdir -p "$root/packages/fixture/scripts"
	printf '%s\n' '{"name":"fixture","version":"2.0.0"}' >"$root/packages/fixture/package.json"
	printf '%s\n' '{"commit":true}' >"$root/packages/fixture/scripts/metadata.json"
	printf '%s\n' '{"name":"monorepo","workspaces":["packages/*"]}' >"$root/package.json"
	tar -czf "$PI_UPDATER_ARCHIVE" -C "$fixture/commit-archive" "fixture-$pinned"
}

for program in "$registry" "$github"; do
	printf '%s\n' '{"lockfileVersion":3,"packages":{"":{"name":"fixture","version":"2.0.0"}}}' >"$PI_UPDATER_LOCK"
	make_commit_archive
	reset_outputs

	if "$program" --pin "${pinned:0:7}"; then
		echo 'An abbreviated commit must fail the updater' >&2
		exit 1
	fi
	unchanged

	"$program" --pin "$pinned"
	grep -Fx "https://github.com/fixture/fixture/archive/$pinned.tar.gz" "$PI_UPDATER_URL"
	jq --sort-keys --arg rev "$pinned" '.pin = {
		owner: "fixture",
		repo: "fixture",
		directory: "packages/fixture",
		rev: $rev,
		hash: "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
		version: "2.0.0"
	}' "$fixture/old-source.json" >"$fixture/expected-source.json"
	jq --sort-keys . source.json | cmp "$fixture/expected-source.json" -
	cmp "$PI_UPDATER_LOCK" npm-deps/package-lock.json
	printf '%s\n' '{"commit":true}' | cmp - metadata.json
	cp source.json "$fixture/pinned-source.json"
	cp npm-deps/package-lock.json "$fixture/pinned-lock.json"

	for arguments in '' --force; do
		# shellcheck disable=SC2086
		"$program" $arguments
		cmp "$fixture/pinned-source.json" source.json
		cmp "$fixture/pinned-lock.json" npm-deps/package-lock.json
	done

	PI_UPDATER_GIT_HEAD='' "$program"
	cmp "$fixture/pinned-source.json" source.json

	printf '%s\n' '{"lockfileVersion":3,"packages":{"":{"name":"fixture","version":"2.0.0"}},"refreshed":true}' >"$PI_UPDATER_LOCK"
	PI_UPDATER_FORBID_DISCOVERY=1 "$program" --refresh
	cmp "$fixture/pinned-source.json" source.json
	cmp "$PI_UPDATER_LOCK" npm-deps/package-lock.json
	grep -Fx "https://github.com/fixture/fixture/archive/$pinned.tar.gz" "$PI_UPDATER_URL"

	printf '%s\n' '{"lockfileVersion":3,"packages":{"":{"name":"fixture","version":"2.0.0"}},"maintained":true}' >"$PI_UPDATER_LOCK"
	PI_UPDATER_FORBID_DISCOVERY=1 "$program" --maintain-lockfile
	cmp "$fixture/pinned-source.json" source.json
	cmp "$PI_UPDATER_LOCK" npm-deps/package-lock.json

	printf '%s\n' '{"lockfileVersion":3,"packages":{"":{"name":"fixture","version":"2.0.0"}}}' >"$PI_UPDATER_LOCK"
	make_archive
	PI_UPDATER_GIT_HEAD="$released" "$program"
	if [[ "$program" == "$registry" ]]; then
		printf '%s\n' '{"tarballHash":"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","version":"2.0.0"}' >"$fixture/expected-source.json"
	else
		printf '%s\n' '{"hash":"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","tag":"v2.0.0","version":"2.0.0"}' >"$fixture/expected-source.json"
	fi
	jq --sort-keys . source.json | cmp <(jq --sort-keys . "$fixture/expected-source.json") -
	cmp "$PI_UPDATER_LOCK" npm-deps/package-lock.json
	cmp "$fixture/archive/package/scripts/metadata.json" metadata.json
done
