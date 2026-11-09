# shellcheck shell=bash

set -euo pipefail

program="$1"
fixture="$(mktemp -d)"
trap 'chmod -R u+w "${fixture}"; rm -rf "${fixture}"' EXIT

# A package directory as pnpm installs it, with a manifest, a `marker` file
# whose contents identify the copy, and the dependencies given as JSON in $4.
package() {
	local directory="$1" name="$2" version="$3" dependencies="$4" marker="$5"

	mkdir -p "${directory}"
	jq -n --arg name "${name}" --arg version "${version}" --argjson dependencies "${dependencies}" \
		'{$name, $version, $dependencies}' >"${directory}/package.json"
	printf '%s\n' "${marker}" >"${directory}/marker"
}

# A tarball in the layout of `npm-tarball.nix`, with every file read-only as
# in the Nix store.
tarball() {
	local name="$1" version="$2" dependencies="$3" marker="$4" source="${fixture}/source/$1"

	package "${source}" "${name}" "${version}" "${dependencies}" "${marker}"
	chmod -R a-w "${source}"
	tar -czf "${fixture}/${name//\//+}.tgz" -C "${source}" --transform 's,^\.,package,' .
}

# A consumer whose virtual store has two copies of `@scope/host`, one per peer
# set, a copy of `linked`, and an unrelated `linked-extra`. The registry
# release of `@scope/host` has no dependencies, but the lockfile installs
# `shared` beside it, as a package extension does.
consumer() {
	local root="$1" host_version="$2"
	local store="${root}/node_modules/.pnpm" peers

	rm -rf "${root}"
	for peers in "(peer@1.0.0)" "(peer@2.0.0)"; do
		package "${store}/@scope+host@${host_version}${peers}/node_modules/@scope/host" @scope/host "${host_version}" '{}' registry
		mkdir "${store}/@scope+host@${host_version}${peers}/node_modules/shared"
	done
	package "${store}/linked@1.0.0/node_modules/linked" linked 1.0.0 '{}' registry
	package "${store}/linked-extra@1.0.0/node_modules/linked-extra" linked-extra 1.0.0 '{}' registry
}

markers() {
	local file

	(cd "$1/node_modules/.pnpm" && find . -name marker | LC_ALL=C sort | while IFS= read -r file; do
		printf '%s %s\n' "${file}" "$(cat "${file}")"
	done)
}

providers() {
	jq -n --arg fixture "${fixture}" '[
		{name: "@scope/host", tarball: "\($fixture)/@scope+host.tgz"},
		{name: "linked", tarball: "\($fixture)/linked.tgz"}
	]' >"${fixture}/provided.json"
}

tarball @scope/host 2.0.0 '{"shared": "^1"}' local
tarball linked 1.0.0 '{}' local
providers

consumer "${fixture}/consumer" 2.0.0
(cd "${fixture}/consumer" && bash "${program}" "${fixture}/provided.json")
diff -u - <(markers "${fixture}/consumer") <<'EOF'
./@scope+host@2.0.0(peer@1.0.0)/node_modules/@scope/host/marker local
./@scope+host@2.0.0(peer@2.0.0)/node_modules/@scope/host/marker local
./linked-extra@1.0.0/node_modules/linked-extra/marker registry
./linked@1.0.0/node_modules/linked/marker local
EOF

# A second run replaces the writable copies left by the first.
(cd "${fixture}/consumer" && bash "${program}" "${fixture}/provided.json")

# A consumer without a virtual store is left alone.
mkdir "${fixture}/empty"
(cd "${fixture}/empty" && bash "${program}" "${fixture}/provided.json")

expect_failure() {
	local message="$1"

	if (cd "${fixture}/consumer" && bash "${program}" "${fixture}/provided.json") 2>"${fixture}/error"; then
		echo "Expected the substitution to fail: ${message}" >&2
		exit 1
	fi
	grep -qFx "${message}" "${fixture}/error"
}

consumer "${fixture}/consumer" 1.5.0
expect_failure "pnpm-lock.yaml resolves @scope/host to 1.5.0, but the local package is 2.0.0. Run the package's updater."

chmod -R u+w "${fixture}/source"
rm -rf "${fixture}/source"
tarball @scope/host 2.0.0 '{"shared": "^1", "added": "^1"}' local
consumer "${fixture}/consumer" 2.0.0
expect_failure "pnpm-lock.yaml does not install added for the local @scope/host 2.0.0. Run the package's updater."

echo "pnpm local package substitution passed."
