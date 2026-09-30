# Tests for the programs in `packages.nix`.
#
# Usage: packages.test.bash <claude> <teamclaude-server>
#
# <claude> is the launcher built around a stand-in Claude Code, which writes
# its arguments and proxy environment as JSON to `$CLAUDE_RESULT`.
# <teamclaude-server> is the server command built around a stand-in
# `teamclaude`, which writes its arguments as JSON to `$TEAMCLAUDE_RESULT`.

set -euo pipefail

claude=$1
server=$2

export HOME="$PWD/home"
export TEAMCLAUDE_CONFIG="$HOME/.config/teamclaude.json"
export CLAUDE_RESULT="$PWD/claude.json"
export TEAMCLAUDE_RESULT="$PWD/teamclaude.json"

failures=0

fail() {
	echo "FAIL: $1" >&2
	failures=$((failures + 1))
}

reset() {
	rm -rf "$HOME" "$CLAUDE_RESULT" "$TEAMCLAUDE_RESULT"
	mkdir -p "$(dirname "$TEAMCLAUDE_CONFIG")"
}

write_config() {
	printf '%s\n' "$1" >"$TEAMCLAUDE_CONFIG"
}

# Listens on a free loopback port, chosen by the kernel, and sets `port` to it.
listen() {
	node -e '
    const server = require("net").createServer(socket => socket.destroy());
    server.listen(0, "127.0.0.1", () => console.log(server.address().port));
  ' >port.txt &
	listener=$!

	for _ in $(seq 100); do
		if [[ -s port.txt ]]; then
			port=$(<port.txt)
			return
		fi

		sleep 0.1
	done

	echo "The test listener did not start" >&2
	exit 1
}

stop_listening() {
	kill "$listener"
	wait "$listener" || true
}

# Runs the launcher and compares what the stand-in Claude Code received, and
# what the launcher printed, with the expected JSON.
check_claude() {
	local name=$1 expected=$2

	"$claude" --print "hello world" 2>stderr.txt

	local actual
	actual=$(jq --sort-keys --rawfile stderr stderr.txt '. + {stderr: $stderr}' "$CLAUDE_RESULT")
	expected=$(jq --sort-keys <<<"$expected")

	if [[ $actual != "$expected" ]]; then
		fail "$name"
		diff -u <(echo "$expected") <(echo "$actual") >&2 || true
	fi
}

direct='{
  "args": ["--print", "hello world"],
  "httpsProxy": null,
  "caFile": null
}'

reset
check_claude "claude without a config starts directly" \
	"$(jq '. + {stderr: ""}' <<<"$direct")"

reset
write_config "not json"
check_claude "claude with an unreadable config starts directly" \
	"$(jq '. + {stderr: "claude: `teamclaude env` failed, so Claude Code is starting without the TeamClaude proxy. Run `teamclaude env` to see why.\n"}' <<<"$direct")"

reset
listen
write_config "{\"proxy\": {\"port\": $port}, \"accounts\": []}"
check_claude "claude with the proxy running goes through it" "{
  \"args\": [\"--print\", \"hello world\"],
  \"httpsProxy\": \"http://127.0.0.1:$port\",
  \"caFile\": \"$HOME/.config/teamclaude-ca.pem\",
  \"stderr\": \"\"
}"

# Nothing listens on the port once the listener has stopped.
stop_listening
check_claude "claude with the proxy stopped starts directly" \
	"$(jq '. + {stderr: "claude: the TeamClaude proxy is not running, so Claude Code is starting without it. Run `teamclaude status` for details.\n"}' <<<"$direct")"

# Runs the server command and compares its exit status, what it printed, and
# the arguments that the stand-in `teamclaude` received, with the expected
# JSON.
check_server() {
	local name=$1 expected=$2 status=0

	"$server" 2>stderr.txt || status=$?

	local teamclaude=null
	if [[ -e $TEAMCLAUDE_RESULT ]]; then
		teamclaude=$(<"$TEAMCLAUDE_RESULT")
	fi

	local actual
	actual=$(jq --null-input --sort-keys \
		--argjson status "$status" \
		--rawfile stderr stderr.txt \
		--argjson teamclaude "$teamclaude" \
		'{status: $status, stderr: $stderr, teamclaude: $teamclaude}')
	expected=$(jq --sort-keys <<<"$expected")

	if [[ $actual != "$expected" ]]; then
		fail "$name"
		diff -u <(echo "$expected") <(echo "$actual") >&2 || true
	fi
}

no_accounts=$(jq --null-input --arg config "$TEAMCLAUDE_CONFIG" '{
  status: 0,
  stderr: "\($config) lists no TeamClaude accounts. Add one with `teamclaude login`.\n",
  teamclaude: null
}')

reset
check_server "the server waits for a config" "$no_accounts"

reset
write_config '{"accounts": []}'
check_server "the server waits for an account" "$no_accounts"

reset
write_config '{"accounts": [{"name": "personal", "type": "oauth"}]}'
check_server "the server starts once there is an account" '{
  "status": 0,
  "stderr": "",
  "teamclaude": ["server", "--headless"]
}'

if ((failures > 0)); then
	echo "$failures test(s) failed" >&2
	exit 1
fi
