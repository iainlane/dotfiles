#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
runtime="${PI_TEST_SUBAGENTS:-$root/node_modules/pi-subagents}"
host="$(command -v "${PI_TEST_HOST:-pi}")"
entry="$(
	cd -- "$runtime"
	node --input-type=module -e '
    import { fileURLToPath } from "node:url";
    process.stdout.write(fileURLToPath(import.meta.resolve("pi-subagents")));
  '
)"
workspace="$(mktemp -d "${TMPDIR:-/tmp}/pi-demo.XXXXXX")"
trap 'rm -rf -- "$workspace"' EXIT

node --no-warnings --experimental-transform-types --input-type=module - "$root" "$workspace" <<'JS'
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [root, workspace] = process.argv.slice(2);
if (!root || !workspace) {
  throw new Error("Expected extension and workspace directories.");
}
const { initialProgram } = await import(
  pathToFileURL(join(root, "demo/scenario.ts")).href
);
mkdirSync(join(workspace, "agent"), { recursive: true });
mkdirSync(join(workspace, "home"), { recursive: true });
mkdirSync(join(workspace, "scratch"), { recursive: true });
writeFileSync(join(workspace, "cleanup.mjs"), initialProgram);
writeFileSync(join(workspace, "scratch/cache.tmp"), "temporary cache\n");
writeFileSync(join(workspace, "scratch/notes.md"), "keep these notes\n");
writeFileSync(
  join(workspace, "agent/settings.json"),
  JSON.stringify({
    theme: "dark",
    externalEditor:
      "vim -Nu NONE -i NONE -n -c 'set number laststatus=2 statusline=PLAN-EDITOR'",
    compaction: { enabled: false },
    retry: { enabled: false },
  }),
);
JS

cd -- "$workspace"
env -i \
	PATH="$PATH" \
	HOME="$workspace/home" \
	XDG_CONFIG_HOME="$workspace/home/.config" \
	XDG_CACHE_HOME="$workspace/home/.cache" \
	TERM=xterm-256color \
	COLORTERM=truecolor \
	LANG=en_US.UTF-8 \
	PI_CODING_AGENT_DIR="$workspace/agent" \
	PI_OFFLINE=1 \
	"$host" --offline --no-extensions --no-mcp --no-skills \
	--no-context-files --no-prompt-templates \
	--tui-mode fullscreen --session-dir "$workspace/sessions" \
	--provider planning-demo --model scripted \
	-e "$entry" -e "$root/index.ts" -e "$root/demo/provider.ts" "$@"
