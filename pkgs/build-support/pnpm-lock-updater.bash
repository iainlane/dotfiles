set -euo pipefail

staged="$(mktemp package.json.XXXXXX)"
trap 'rm -f "$staged"' EXIT

# pnpm turns a global override of the project's own peer into a production
# dependency. For a local package that the project declares as a peer, the
# project's dependency points at the tarball instead. After the first relock,
# the updater adds an override scoped to each package that depends on it.
peers="$(jq -c '.peerDependencies // {} | keys' package.json)"

jq --slurpfile providers "$1" --argjson peers "$peers" '
  reduce $providers[0][] as $package (.;
    reduce ["dependencies", "devDependencies", "optionalDependencies"][] as $field (.;
      if .[$field] == null then .
      else .[$field] |= with_entries(
        if .value == ("npm:" + $package.name) or
           (.value | startswith("npm:" + $package.name + "@"))
        then .value = "npm:" + $package.name + "@" + $package.version
        elif .key == $package.name and ($peers | index($package.name))
        then .value = "file:.nix-providers/" + $package.file
        elif .key == $package.name and (.value | startswith("npm:") | not)
        then .value = $package.version
        else . end)
      end))
' package.json >"$staged"
mv "$staged" package.json

# Point each local package's override at its tarball in .nix-providers and drop
# overrides for packages that the lockfile no longer uses.
override() {
	name="$1" value="file:.nix-providers/$2" yq -i '.overrides[strenv(name)] = strenv(value)' pnpm-workspace.yaml
}

yq -i '.overrides = ((.overrides // {}) | with_entries(select(.value | tostring | test("^file:\.nix-providers/") | not)))' pnpm-workspace.yaml
while IFS=$'\t' read -r name file; do
	override "$name" "$file"
done < <(jq -r --argjson peers "$peers" '.[] | select(.name as $name | $peers | index($name) | not) | [.name, .file] | @tsv' "$1")
yq -i 'del(.overrides | select(length == 0))' pnpm-workspace.yaml

relock() {
	pnpm install --lockfile-only --no-frozen-lockfile --ignore-scripts
}

# Prints each direct dependency that a local package resolves to another
# version, with the versions that the local packages resolve. pnpm would
# install a second copy, and each copy would load with its own module state.
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
		| (
			.importers["."] // {}
			| (.dependencies // {}) + (.devDependencies // {}) + (.optionalDependencies // {})
			| with_entries(select(.value.version | test("^[0-9]")) | .value = (.value.version | version))
		) as $direct
		| $provided | group_by(.name)[]
		| {name: .[0].name, versions: (map(.version) | unique)}
		| select($direct[.name] != null and .versions != [$direct[.name]])
		| [.name, (.versions | join(" "))] | @tsv'
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

relock

scoped=0
while IFS=$'\t' read -r name file; do
	while IFS= read -r parent; do
		override "$parent>$name" "$file"
		scoped=1
	done < <(dependents "$name")
done < <(jq -r --argjson peers "$peers" '.[] | select(.name as $name | $peers | index($name)) | [.name, .file] | @tsv' "$1")
if ((scoped)); then
	relock
fi

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

	jq --arg name "$name" --arg version "$versions" '
		reduce ["dependencies", "devDependencies", "optionalDependencies"][] as $field (.;
			if .[$field][$name] == null or (.[$field][$name] | startswith("npm:")) then .
			else .[$field][$name] = $version end)
	' package.json >"$staged"
	mv "$staged" package.json
done

relock

mapfile -t mismatches < <(misaligned)
for mismatch in "${mismatches[@]}"; do
	printf 'pnpm still installs a second copy of %s beside a local package.\n' "${mismatch%%$'\t'*}" >&2
	exit 1
done
