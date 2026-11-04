# shellcheck shell=bash

# Usage: npm-lock-updater.bash PROVIDED
#
# PROVIDED is a JSON file listing the local npm packages that the build
# installs, each with its `name` and `version`. Run from the directory that
# contains package.json.

set -euo pipefail

provided="$1"

sections='["dependencies", "devDependencies", "optionalDependencies"]'

# Run `npm install` for each line of $1: a package.json section, a tab, then
# install specs separated by spaces.
install() {
	local changes="$1" section specs flag

	while [[ -n "${changes}" ]] && IFS=$'\t' read -r section specs; do
		case "${section}" in
		dependencies)
			flag=--save-prod
			;;
		devDependencies)
			flag=--save-dev
			;;
		optionalDependencies)
			flag=--save-optional
			;;
		esac

		read -ra specs <<<"${specs}"
		npm install --package-lock-only --ignore-scripts --save-exact "${flag}" "${specs[@]}"
	done <<<"${changes}"
}

# Print the lockfile entries that resolve a local package to a version other
# than the local one.
mismatches() {
	jq -r --slurpfile packages "${provided}" '
		.packages
		| to_entries[] as $entry
		| $packages[0][] as $package
		| select(($entry.value.name // ($entry.key | sub(".*node_modules/"; ""))) == $package.name)
		| select($entry.value.version != $package.version)
		| "  \($entry.key): \($entry.value.version) (local \($package.version))"
	' package-lock.json
}

# For each dependency that package.json declares directly and that npm installs
# again under a local package, at a version other than the top-level copy,
# print the version that each local package resolves it to.
nested() {
	jq --slurpfile root package.json --slurpfile provided "${provided}" --argjson sections "${sections}" '
		def package_name($path; $entry): $entry.name // ($path | sub(".*node_modules/"; ""));

		# Node resolves a dependency from the nearest node_modules directory,
		# walking up from the dependant.
		def resolve($packages; $from; $dependency):
			($from | ltrimstr("node_modules/") | split("/node_modules/")) as $parts
			| [
				range($parts | length; -1; -1) as $depth
				| "node_modules/" + (($parts[0:$depth] + [$dependency]) | join("/node_modules/"))
				| select($packages[.] != null)
			]
			| first;

		.packages as $packages
		| ($provided[0] | map(.name)) as $local
		| [
			$packages
			| to_entries[]
			| select(.key != "" and (package_name(.key; .value) as $name | $local | index($name)))
			| .key as $from
			| (.value.dependencies // {}) + (.value.optionalDependencies // {})
			| keys[] as $dependency
			| first($sections[] | select($root[0][.] // {} | has($dependency))) as $section
			| resolve($packages; $from; $dependency) as $path
			| select($path != null and $path != "node_modules/\($dependency)")
			| select($packages[$path].version != $packages["node_modules/\($dependency)"].version)
			| {$section, $dependency, version: $packages[$path].version, $from}
		]
		| group_by(.dependency)
	' package-lock.json
}

# Pin each local package, and any alias of it, to its local version.
install "$(jq -r --slurpfile provided "${provided}" --argjson sections "${sections}" '
	. as $root
	| [
		$provided[0][] as $package
		| $sections[] as $section
		| $root[$section] // {}
		| to_entries[]
		| if .key == $package.name and .value != $package.version then
			{section: $section, spec: "\(.key)@\($package.version)"}
		elif (.value | startswith("npm:\($package.name)@")) and .value != "npm:\($package.name)@\($package.version)" then
			{section: $section, spec: "\(.key)@npm:\($package.name)@\($package.version)"}
		else
			empty
		end
	]
	| group_by(.section)[]
	| "\(.[0].section)\t\(map(.spec) | join(" "))"
' package.json)"

# npm does not install a package's own peer dependencies, so it cannot save
# them. Set the peer specs for local packages directly.
peers="$(jq --slurpfile provided "${provided}" '
	reduce $provided[0][] as $package (.;
		if (.peerDependencies // {}) | has($package.name) then
			.peerDependencies[$package.name] = $package.version
		else
			.
		end)
' package.json)"
peers_changed=false
if [[ "${peers}" != "$(jq . package.json)" ]]; then
	printf '%s\n' "${peers}" >package.json
	peers_changed=true
fi

# The lockfile records package.json's peer specs, and it can be stale although
# package.json already pins the local versions.
if [[ "${peers_changed}" == true || -n "$(mismatches)" ]]; then
	npm install --package-lock-only --ignore-scripts
fi

# Where npm installs a second copy of a dependency under local packages, move
# the direct dependency to that copy's version. Two copies load as two module
# instances, each with its own state, such as pi-tui's global theme. Local
# packages that nest different versions are a conflict.
groups="$(nested)"
conflicts="$(jq -r '
	.[]
	| select(map(.version) | unique | length > 1)
	| "  \(.[0].dependency): \(map("\(.version) (\(.from))") | join(", "))"
' <<<"${groups}")"

if [[ -n "${conflicts}" ]]; then
	echo "Local npm packages resolve these dependencies to different versions:" >&2
	printf '%s\n' "${conflicts}" >&2
	exit 1
fi

install "$(jq -r '
	map(.[0])
	| group_by(.section)[]
	| "\(.[0].section)\t\(map("\(.dependency)@\(.version)") | join(" "))"
' <<<"${groups}")"

remaining="$(nested | jq -r '
	.[]
	| "  \(.[0].dependency): \(map(.version) | unique | join(", ")) under \(map(.from) | join(", "))"
')"

if [[ -n "${remaining}" ]]; then
	echo "npm still installs a second copy of these dependencies under local npm packages:" >&2
	printf '%s\n' "${remaining}" >&2
	exit 1
fi

stale="$(mismatches)"

if [[ -n "${stale}" ]]; then
	echo "The lockfile resolves these entries to versions that differ from the local npm packages' versions:" >&2
	printf '%s\n' "${stale}" >&2
	exit 1
fi
