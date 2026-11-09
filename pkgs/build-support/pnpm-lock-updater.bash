# shellcheck shell=bash

# Usage: pnpm-lock-updater.bash PROVIDED
#
# PROVIDED is a JSON file listing the local npm packages that the build
# installs, each with its `name`, `version` and `tarball`. Run from the
# directory that contains package.json and pnpm-workspace.yaml.

set -euo pipefail

provided="$1"
staged="$(mktemp)"
trap 'rm -f "${staged}"' EXIT

# Pin each local package, and any alias of it, to its local version.
jq --slurpfile providers "${provided}" '
  reduce $providers[0][] as $package (.;
    reduce ["dependencies", "devDependencies", "optionalDependencies"][] as $field (.;
      if .[$field] == null then .
      else .[$field] |= with_entries(
        if .value == ("npm:" + $package.name) or
           (.value | startswith("npm:" + $package.name + "@"))
        then .value = "npm:" + $package.name + "@" + $package.version
        elif .key == $package.name and (.value | startswith("npm:") | not)
        then .value = $package.version
        else . end)
      end))
' package.json >"${staged}"
cat "${staged}" >package.json

# pnpm resolves a package's dependencies from its registry manifest. Where a
# local package declares dependencies that differ from its registry release,
# record the differences as a package extension so the lockfile installs what
# the local package requires.
extensions="$(
	jq -r '.[] | [.name, .version, .tarball] | @tsv' "${provided}" |
		while IFS=$'\t' read -r name version tarball; do
			registry="$(npm view "${name}@${version}" --json)"
			tar -xzOf "${tarball}" package/package.json |
				jq --arg key "${name}@${version}" --argjson registry "${registry}" '
					. as $local
					| reduce ("dependencies", "optionalDependencies", "peerDependencies", "peerDependenciesMeta") as $field ({};
						($local[$field] // {}
							| with_entries(select(.value != ($registry[$field] // {})[.key]))) as $changed
						| if $changed == {} then . else .[$field] = $changed end)
					| if . == {} then {} else {($key): .} end'
		done |
		jq -s 'add // {}'
)"

yq -o json pnpm-workspace.yaml |
	jq --slurpfile providers "${provided}" --argjson extensions "${extensions}" '
		($providers[0] | map(.name + "@")) as $local
		| (.packageExtensions // {}
			| with_entries(select(.key as $key | $local | any(. as $prefix | $key | startswith($prefix)) | not)))
			+ $extensions
	' >"${staged}"

if [[ "$(jq length "${staged}")" == 0 ]]; then
	yq -i 'del(.packageExtensions)' pnpm-workspace.yaml
else
	EXTENSIONS="${staged}" yq -i '
		.packageExtensions = load(strenv(EXTENSIONS))
		| (.packageExtensions | .. | (., key)) style=""
		| (.packageExtensions | .[] | .. | (select(tag == "!!str"), (key | select(test("^@"))))) style="double"
	' pnpm-workspace.yaml
fi

pnpm install --lockfile-only --no-frozen-lockfile --ignore-scripts
