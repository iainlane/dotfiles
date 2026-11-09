set -euo pipefail

staged="$(mktemp package.json.XXXXXX)"
trap 'rm -f "$staged"' EXIT

jq --slurpfile providers "$1" '
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
' package.json >"$staged"
mv "$staged" package.json

pnpm install --lockfile-only --no-frozen-lockfile --ignore-scripts
