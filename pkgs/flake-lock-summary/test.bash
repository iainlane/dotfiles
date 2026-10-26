#!/usr/bin/env bash
set -euo pipefail

summary="${1:?usage: test.bash <summary-script>}"
directory="$(mktemp -d)"
trap 'rm -rf "$directory"' EXIT

for state in before after; do
	revision=111111111
	dependency=aaaaaaaaa
	if [[ "$state" == after ]]; then
		revision=222222222
		dependency=bbbbbbbbb
	fi

	jq -n --arg revision "$revision" --arg dependency "$dependency" '{
    nodes: {
      root: {
        inputs: {
          "hermes-agent": "hermes-agent",
          uv2nix: ["hermes-agent", "uv2nix"],
          "uv2nix-alias": ["uv2nix"]
        }
      },
      "hermes-agent": {
        inputs: { uv2nix: "uv2nix" },
        locked: { rev: $revision }
      },
      uv2nix: { locked: { rev: $dependency } }
    }
  }' >"$directory/$state.json"
done

actual="$(bash "$summary" "$directory/before.json" "$directory/after.json")"
expected="- \`hermes-agent\`: \`1111111\` → \`2222222\`
- \`uv2nix\`: \`aaaaaaa\` → \`bbbbbbb\`
- \`uv2nix-alias\`: \`aaaaaaa\` → \`bbbbbbb\`"

if [[ "$actual" != "$expected" ]]; then
	printf 'Expected:\n%s\nActual:\n%s\n' "$expected" "$actual" >&2
	exit 1
fi
