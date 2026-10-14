# Tests for `pluginSync` in `packages.nix`.
#
# Usage: plugin-sync.test.bash <herdr> <herdr-plugin-sync>
#
# The test creates plugins in a directory that it passes to the sync as the
# store directory, and in a directory outside it. It runs the real Herdr with
# no server, so every command edits Herdr's plugin registry directly.

set -euo pipefail

herdr=$1
sync_program=$2
store="$PWD/store"

export HOME="$PWD/home"
unset XDG_CONFIG_HOME XDG_STATE_HOME

failures=0

sync() {
	"$sync_program" "$store" "$@"
}

fail() {
	echo "FAIL: $1" >&2
	failures=$((failures + 1))
}

reset() {
	rm -rf "$HOME" "$store" "$PWD/elsewhere"
	mkdir -p "$HOME" "$store" "$PWD/elsewhere"
}

# Creates a plugin directory with a manifest for the plugin `id`.
plugin() {
	local root=$1
	local id=$2

	mkdir -p "$root"
	cat >"$root/herdr-plugin.toml" <<EOF
id = "$id"
name = "$id"
version = "1.0.0"
min_herdr_version = "0.9.0"
platforms = ["linux", "macos"]
EOF
}

# The linked plugins, sorted by ID, as `{id, root, enabled}`.
linked() {
	"$herdr" plugin list --json |
		jq --compact-output '[.result.plugins[] | {id: .plugin_id, root: .plugin_root, enabled}] | sort_by(.id)'
}

expect_linked() {
	local name=$1
	local expected
	local actual

	expected=$(jq --compact-output 'sort_by(.id)' <<<"$2")
	actual=$(linked)

	if [[ $actual != "$expected" ]]; then
		fail "$name: expected $expected, got $actual"
	fi
}

# Links and enables every plugin that is given.
reset
plugin "$store/a" test.a
plugin "$store/b" test.b
sync "$store/a" "$store/b" >/dev/null
expect_linked "links every plugin" "[
  {\"id\": \"test.a\", \"root\": \"$store/a\", \"enabled\": true},
  {\"id\": \"test.b\", \"root\": \"$store/b\", \"enabled\": true}
]"

# Removes a plugin from the store that is no longer given, and reports it.
output=$(sync "$store/a")
expect_linked "removes a plugin that is no longer given" "[
  {\"id\": \"test.a\", \"root\": \"$store/a\", \"enabled\": true}
]"
if [[ $output != "Removed the Herdr plugin test.b, which the configuration no longer lists." ]]; then
	fail "reports the removed plugin: got '$output'"
fi
if [[ ! -f "$store/b/herdr-plugin.toml" ]]; then
	fail "keeps the files of a removed plugin"
fi

# Moves a plugin to its new root when its package changes.
plugin "$store/a2" test.a
sync "$store/a2" >/dev/null
expect_linked "moves a plugin to its new root" "[
  {\"id\": \"test.a\", \"root\": \"$store/a2\", \"enabled\": true}
]"

# Enables a given plugin that was disabled by hand. `herdr plugin disable`
# needs a running server, so the test links the plugin disabled instead.
"$herdr" plugin link "$store/a2" --disabled >/dev/null
expect_linked "the test setup disables test.a" "[
  {\"id\": \"test.a\", \"root\": \"$store/a2\", \"enabled\": false}
]"
sync "$store/a2" >/dev/null
expect_linked "enables a disabled plugin" "[
  {\"id\": \"test.a\", \"root\": \"$store/a2\", \"enabled\": true}
]"

# Leaves a plugin alone when it is linked from outside the store.
reset
plugin "$PWD/elsewhere/c" test.c
"$herdr" plugin link "$PWD/elsewhere/c" --enabled >/dev/null
sync >/dev/null
expect_linked "keeps a plugin from outside the store" "[
  {\"id\": \"test.c\", \"root\": \"$PWD/elsewhere/c\", \"enabled\": true}
]"

if ((failures > 0)); then
	echo "$failures test(s) failed" >&2
	exit 1
fi

echo "All plugin sync tests passed."
