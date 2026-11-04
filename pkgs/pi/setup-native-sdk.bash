#!/usr/bin/env bash
set -euo pipefail

sdk=${1:-${PI_NATIVE_SDK:-}}
if [[ -z "$sdk" || ! -f "$sdk/package.json" ]]; then
	printf '%s\n' 'Provide the patched SDK package directory as an argument or PI_NATIVE_SDK.' >&2
	exit 1
fi
if [[ ! -d node_modules ]]; then
	printf '%s\n' 'Run npm ci in the extension directory before linking the patched SDK.' >&2
	exit 1
fi
sdk=$(cd "$sdk" && pwd -P)

node --input-type=module - "$sdk" <<'JS'
import assert from "node:assert/strict";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
const sdk = await import(pathToFileURL(join(process.argv[2], "dist/index.js")).href);
assert.equal(typeof sdk.resolveToCwd, "function", "The SDK must export resolveToCwd");
assert.equal(typeof sdk.ToolExecutionComponent.prototype.getCallLabel, "function", "The SDK must support resolved tool headings");
JS

packages=(
	'@earendil-works/pi-coding-agent'
	'@earendil-works/pi-agent-core'
	'@earendil-works/pi-ai'
	'@earendil-works/pi-tui'
	'typebox'
)
for package in "${packages[@]}"; do
	target="$sdk/node_modules/$package"
	if [[ "$package" == '@earendil-works/pi-coding-agent' ]]; then
		target=$sdk
	fi
	if [[ ! -f "$target/package.json" ]]; then
		printf 'The SDK does not include %s.\n' "$package" >&2
		exit 1
	fi
done
for package in "${packages[@]}"; do
	target="$sdk/node_modules/$package"
	if [[ "$package" == '@earendil-works/pi-coding-agent' ]]; then
		target=$sdk
	fi
	mkdir -p "node_modules/$(dirname "$package")"
	rm -rf -- "node_modules/$package"
	ln -s "$target" "node_modules/$package"
done
printf 'Linked the native SDK from %s.\n' "$sdk"
