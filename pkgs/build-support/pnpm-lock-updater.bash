set -euo pipefail

catalogue="$1"
providers="$2"
root="$3"

staged=''
trap 'rm -f "$staged"' EXIT

# The manifests of the root and of each workspace member. pnpm-workspace.yaml
# lists the members as glob patterns, and a pattern that starts with `!`
# excludes the members that it matches.
manifests=(package.json)
declare -A skipped=(["package.json"]=1)
mapfile -t patterns < <(yq '.packages // [] | .[]' pnpm-workspace.yaml)

shopt -s globstar
for pattern in "${patterns[@]}"; do
	if [[ "$pattern" == '!'* ]]; then
		while IFS= read -r manifest; do
			skipped["${manifest#./}"]=1
		done < <(compgen -G "${pattern#!}/package.json")
	fi
done
for pattern in "${patterns[@]}"; do
	if [[ "$pattern" == '!'* ]]; then
		continue
	fi
	while IFS= read -r manifest; do
		manifest="${manifest#./}"
		if [[ -z "${skipped[$manifest]-}" ]]; then
			skipped["$manifest"]=1
			manifests+=("$manifest")
		fi
	done < <(compgen -G "$pattern/package.json")
done

declare -A files=() installables=() tarballs=()
while IFS=$'\t' read -r name file installable; do
	files["$name"]="$file"
	installables["$name"]="$installable"
done < <(jq -r '.[] | [.name, .file, .installable] | @tsv' "$catalogue")

# The local package that each override installs, keyed by the override's name.
# An override of a package's name does not reach an npm alias of it, such as
# `"old-name": "npm:new-name@1.0.0"`, so each alias needs its own override.
declare -A needed=()

# pnpm turns a global override of the project's own peer into a production
# dependency. For a local package that a manifest declares as a peer, the
# manifests' dependencies point at the tarball instead. After each relock, the
# updater adds an override scoped to each package that depends on it.
peers="$(jq -s -c 'map(.peerDependencies // {} | keys[]) | unique' "${manifests[@]}")"

peer() {
	jq -e --arg name "$1" 'index($name) != null' <<<"$peers" >/dev/null
}

# `installs` turns a dependency entry into the override's name and the name of
# the package that the entry installs. The two differ for an npm alias.
definitions='
	def package_name: if startswith("@") then "@" + (.[1:] | split("@")[0]) else split("@")[0] end;
	def installs:
		if .value | startswith("npm:")
		then [.key, (.value[4:] | package_name)]
		else [.key, .key] end;
'

# Prints each direct dependency of the root or of a workspace member on a local
# package or on an npm alias of one, as the override's name and the local
# package's name.
direct() {
	jq -r --slurpfile catalogue "$catalogue" "$definitions"'
		INDEX($catalogue[0][]; .name) as $local
		| .dependencies, .devDependencies, .optionalDependencies, .peerDependencies
		| select(. != null)
		| to_entries[] | installs
		| select($local[.[1]] != null)
		| @tsv' "${manifests[@]}"
}

# Prints, in the same form, each runtime dependency of the given local package
# on another local package. The catalogue includes these dependencies for the
# packages in this repository.
follow() {
	jq -r --arg name "$1" "$definitions"'
		INDEX(.[]; .name) as $local
		| $local[$name].dependencies
		| to_entries[] | installs
		| select($local[.[1]] != null)
		| @tsv' "$catalogue"
}

# Prints, in the same form, each local package that the lockfile resolves from
# the registry and each npm alias of a local package.
resolved() {
	yq -o=json '.' pnpm-lock.yaml | jq -r --slurpfile catalogue "$catalogue" "$definitions"'
		INDEX($catalogue[0][]; .name) as $local
		| (
			.packages // {} | keys[]
			| package_name as $name
			| select($local[$name] != null)
			| select(.[($name | length) + 1:] | startswith("file:.nix-providers/") | not)
			| [$name, $name]
		), (
			(
				.importers // {} | .[]
				| .dependencies, .devDependencies, .optionalDependencies
				| select(. != null) | to_entries[] | .value |= .version
			), (
				.snapshots // {} | .[]
				| .dependencies, .optionalDependencies
				| select(. != null) | to_entries[]
			)
			| select(.value | test("^([0-9]|file:|link:)") | not)
			| [.key, (.value | package_name)]
			| select(.[0] != .[1] and $local[.[1]] != null)
		)
		| @tsv'
}

# Adds the overrides that are not needed yet. Each alias also adds its local
# package, so the tarball is linked and the alias in the manifests gets a range
# of the local package's version. A local package that was not needed yet also
# adds its own dependencies on local packages. pnpm cannot resolve a private one
# from the registry, so the relock would fail before the lockfile could show it.
add() {
	local name target known dependencies
	while IFS=$'\t' read -r name target; do
		if [[ -z "$name" ]]; then
			continue
		fi
		known="${needed[$target]-}"
		needed["$name"]="${needed[$name]-$target}"
		needed["$target"]="${needed[$target]-$target}"
		if [[ -z "$known" ]]; then
			dependencies="$(follow "$target")"
			add "$dependencies"
		fi
	done <<<"$1"
}

# Prints the needed overrides, each local package followed by its aliases.
overrides() {
	local name rank
	for name in "${!needed[@]}"; do
		rank=1
		if [[ "$name" == "${needed[$name]}" ]]; then
			rank=0
		fi
		printf '%s\t%s\t%s\n' "$name" "${needed[$name]}" "$rank"
	done | LC_ALL=C sort -t $'\t' -k2,2 -k3,3 -k1,1 | cut -f 1,2
}

link() {
	local arguments=() name target
	while IFS=$'\t' read -r name target; do
		if [[ "$name" != "$target" ]]; then
			continue
		fi
		if [[ -z "${tarballs[$target]-}" ]]; then
			tarballs["$target"]="$(cd "$root" && nix build --no-link --print-out-paths "${installables[$target]}")/package.tgz"
		fi
		arguments+=("${files[$target]}" "${tarballs[$target]}")
	done < <(overrides)
	bash "$providers" link . "${arguments[@]}"
}

# Points the manifests' dependencies on the needed local packages at caret
# ranges of their versions, or at their tarballs for the workspace's peers.
retarget() {
	local manifest selected
	selected="$(overrides | cut -f 2 | jq -R . | jq -s --slurpfile catalogue "$catalogue" '. as $names | $catalogue[0] | map(select(.name as $name | $names | index($name)))')"

	for manifest in "${manifests[@]}"; do
		staged="$(mktemp "$manifest.XXXXXX")"
		jq --argjson providers "$selected" --argjson peers "$peers" '
			reduce $providers[] as $package (.;
				reduce ["dependencies", "devDependencies", "optionalDependencies"][] as $field (.;
					if .[$field] == null then .
					else .[$field] |= with_entries(
						if .value == ("npm:" + $package.name) or
							 (.value | startswith("npm:" + $package.name + "@"))
						then .value = "npm:" + $package.name + "@^" + $package.version
						elif .key == $package.name and ($peers | index($package.name))
						then .value = "file:.nix-providers/" + $package.file
						elif .key == $package.name and (.value | startswith("npm:") | not)
						then .value = "^" + $package.version
						else . end)
					end))
		' "$manifest" >"$staged"
		mv "$staged" "$manifest"
	done
}

override() {
	name="$1" value="file:.nix-providers/$2" yq -i '.overrides[strenv(name)] = strenv(value)' pnpm-workspace.yaml
}

# yq and pnpm write a key such as `@scope/name` with single quotes, and the
# repository's formatter rewrites them as double quotes.
relock() {
	pnpm install --lockfile-only --no-frozen-lockfile --ignore-scripts
	yq -i '(... | select(style == "single")) style = "double"' pnpm-workspace.yaml
}

# Prints each package that resolves the registry release of the given local
# package.
dependents() {
	yq -o=json '.snapshots // {}' pnpm-lock.yaml | jq -r --arg name "$1" '
		to_entries[]
		| select(((.value.dependencies // {}) + (.value.optionalDependencies // {}))[$name] // "" | test("^[0-9]"))
		| .key | sub("\\(.*$"; "")
		| if startswith("@") then "@" + (.[1:] | split("@")[0]) else split("@")[0] end' |
		LC_ALL=C sort -u
}

# Prints each direct dependency of the root or of a workspace member that a
# local package resolves to another version, with the versions that the local
# packages resolve. pnpm would install a second copy, and each copy would load
# with its own module state.
misaligned() {
	yq -o=json '.' pnpm-lock.yaml | jq -r '
		def version: sub("\\(.*$"; "");
		[
			.snapshots // {} | to_entries[]
			| select(.key | test("@file:\\.nix-providers/"))
			| (.value.dependencies // {}) + (.value.optionalDependencies // {})
			| to_entries[]
			| select(.value | test("^[0-9]"))
			| {name: .key, version: (.value | version)}
		] as $provided
		| [
			.importers // {} | .[]
			| (.dependencies // {}) + (.devDependencies // {}) + (.optionalDependencies // {})
			| to_entries[]
			| select(.value.version | test("^[0-9]"))
			| {name: .key, version: (.value.version | version)}
		] as $direct
		| $provided | group_by(.name)[]
		| {name: .[0].name, versions: (map(.version) | unique)}
		| .name as $name
		| ($direct | map(select(.name == $name) | .version) | unique) as $installed
		| select($installed != [] and $installed != .versions)
		| [.name, (.versions | join(" "))] | @tsv'
}

# Remove the overrides that earlier runs wrote. The rounds below write one for
# each local package that the project still uses.
yq -i '.overrides = ((.overrides // {}) | with_entries(select(.value | tostring | test("^file:\.nix-providers/") | not)))' pnpm-workspace.yaml

# A local package that no manifest mentions can reach the lockfile through a
# registry package that depends on it. Each round overrides the local packages
# and aliases that the previous relock resolved from the registry, and relocks
# again.
add "$(direct)"
rounds=0
while true; do
	if ((++rounds > 10)); then
		echo 'Relocking still added local npm packages after 10 rounds.' >&2
		exit 1
	fi

	link
	retarget
	while IFS=$'\t' read -r name target; do
		if ! peer "$name"; then
			override "$name" "${files[$target]}"
		fi
	done < <(overrides)
	yq -i 'del(.overrides | select(length == 0))' pnpm-workspace.yaml
	relock

	scoped=0
	while IFS=$'\t' read -r name target; do
		if ! peer "$name"; then
			continue
		fi
		while IFS= read -r parent; do
			override "$parent>$name" "${files[$target]}"
			scoped=1
		done < <(dependents "$name")
	done < <(overrides)
	if ((scoped)); then
		relock
	fi

	count="${#needed[@]}"
	add "$(resolved)"
	if ((${#needed[@]} == count)); then
		break
	fi
done

mapfile -t mismatches < <(misaligned)
if ((${#mismatches[@]} == 0)); then
	exit 0
fi

for mismatch in "${mismatches[@]}"; do
	IFS=$'\t' read -r name versions <<<"$mismatch"
	if [[ "$versions" == *" "* ]]; then
		printf 'Local packages need different versions of %s: %s\n' "$name" "$versions" >&2
		exit 1
	fi

	# pnpm resolves a caret range to the newest matching release even when a
	# local package installs an older one, so the pin stays exact.
	for manifest in "${manifests[@]}"; do
		staged="$(mktemp "$manifest.XXXXXX")"
		jq --arg name "$name" --arg version "$versions" '
			reduce ["dependencies", "devDependencies", "optionalDependencies"][] as $field (.;
				if .[$field][$name] == null or (.[$field][$name] | startswith("npm:")) then .
				else .[$field][$name] = $version end)
		' "$manifest" >"$staged"
		mv "$staged" "$manifest"
	done
done

relock

mapfile -t mismatches < <(misaligned)
for mismatch in "${mismatches[@]}"; do
	printf 'pnpm still installs a second copy of %s beside a local package.\n' "${mismatch%%$'\t'*}" >&2
	exit 1
done
