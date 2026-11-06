#!/usr/bin/env bash
set -euo pipefail

activation=$1
defaults=$2
runtime=$3
expected=$4
previousGeneration=$5
relative=.pi/agent/extensions/pi-permission-system/config.json

export HOME="$TMPDIR/permission-config-home"
config="$HOME/$relative"

assert_json() {
	jq --sort-keys . "$1" >"$TMPDIR/actual.json"
	jq --sort-keys . "$2" >"$TMPDIR/expected.json"
	cmp "$TMPDIR/expected.json" "$TMPDIR/actual.json"
}

bash "$activation"
test -f "$config" && test ! -L "$config"
test "$(stat -c %a "$config")" = 600
assert_json "$config" "$defaults"

cp "$runtime" "$config"
bash "$activation"
assert_json "$config" "$expected"
inode=$(stat -c %i "$config")
bash "$activation"
test "$(stat -c %i "$config")" = "$inode"
assert_json "$config" "$expected"

rm "$config"
export oldGenPath="$previousGeneration"
bash "$activation"
test ! -L "$config" && test -w "$config"
assert_json "$config" "$expected"

for invalid in '{' '[]'; do
	printf '%s\n' "$invalid" >"$config"
	cp "$config" "$TMPDIR/invalid.json"
	if bash "$activation" >"$TMPDIR/errors" 2>&1; then
		printf '%s\n' 'Activation accepted an invalid permission config.' >&2
		exit 1
	fi
	cmp "$TMPDIR/invalid.json" "$config"
done

rm "$config"
ln -s "$runtime" "$config"
if bash "$activation" >"$TMPDIR/errors" 2>&1; then
	printf '%s\n' 'Activation accepted an external configuration symlink.' >&2
	exit 1
fi
test -L "$config"
test "$(readlink "$config")" = "$runtime"

HOME="$TMPDIR/permission-config-dry-home" DRY_RUN=1 bash "$activation"
test ! -e "$TMPDIR/permission-config-dry-home"
