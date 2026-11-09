import { spawn } from "node:child_process";
import { once } from "node:events";
import {
  lstatSync,
  readdirSync,
  realpathSync,
  readFileSync,
  mkdtempSync,
  mkdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import assert from "node:assert/strict";

async function check(directory: string): Promise<void> {
  const root = realpathSync(directory);
  const forbidden = new Set([
    "test",
    ".fixtures",
    "demo",
    "scripts",
    "pnpm-lock.yaml",
  ]);
  for (const entry of readdirSync(root)) {
    assert.ok(!forbidden.has(entry), `Unexpected deployment entry: ${entry}`);
  }
  const visit = (path: string): void => {
    const stat = lstatSync(path);
    if (stat.isSymbolicLink()) {
      assert.ok(
        realpathSync(path).startsWith(`${root}/`),
        `External dependency link: ${path}`,
      );
      return;
    }
    if (!stat.isDirectory()) {
      if (path.endsWith("/package.json")) {
        const value: unknown = JSON.parse(readFileSync(path, "utf8"));
        assert.ok(
          typeof value === "object" &&
            value !== null &&
            "name" in value &&
            typeof value.name === "string",
        );
        const name = value.name;
        assert.ok(
          !name.startsWith("@earendil-works/") &&
            !name.startsWith("@mariozechner/") &&
            ![
              "typescript",
              "vitest",
              "oxlint",
              "@xterm/headless",
              "@homebridge/node-pty-prebuilt-multiarch",
              "typebox",
            ].includes(name),
          `Development or host peer in deployment: ${name}`,
        );
      }
      return;
    }
    for (const entry of readdirSync(path)) {
      visit(join(path, entry));
    }
  };
  visit(join(root, "node_modules"));
  const host = process.env.PI_TEST_HOST;
  assert.ok(
    host !== undefined,
    "Set PI_TEST_HOST to check the deployed extension with native Pi",
  );
  const home = realpathSync(mkdtempSync(join(tmpdir(), "footer-deployment-")));
  const cwd = join(home, "unrelated-workspace");
  const agent = join(home, "agent");
  mkdirSync(cwd);
  mkdirSync(agent);
  writeFileSync(join(agent, "settings.json"), '{"quietStartup":true}');
  const child = spawn(
    host,
    [
      "--offline",
      "--no-extensions",
      "-e",
      join(root, "index.ts"),
      "--no-mcp",
      "--no-skills",
      "--no-context-files",
      "--no-prompt-templates",
      "--no-tools",
      "--mode",
      "rpc",
    ],
    {
      cwd,
      env: {
        PATH: process.env.PATH,
        HOME: home,
        PI_CODING_AGENT_DIR: agent,
        PI_OFFLINE: "1",
      },
      stdio: ["pipe", "pipe", "pipe"],
    },
  );
  let output = "";
  let errorOutput = "";
  child.stdout.on("data", (value: Buffer) => {
    output += value.toString();
    if (output.includes('"id":"footer-load"')) {
      child.stdin.end();
    }
  });
  child.stderr.on("data", (value: Buffer) => {
    errorOutput += value.toString();
  });
  const timeout = setTimeout(() => {
    child.kill("SIGKILL");
  }, 30_000);
  child.stdin.write('{"id":"footer-load","type":"get_commands"}\n');
  try {
    const exited: unknown[] = await once(child, "close");
    assert.equal(exited[0], 0, output + errorOutput);
    assert.match(output, /"name":"footer"/);
    assert.doesNotMatch(
      output + errorOutput,
      /ERR_MODULE_NOT_FOUND|Cannot find module|Failed to load extension/,
    );
  } finally {
    clearTimeout(timeout);
    rmSync(home, { recursive: true, force: true });
  }
}

try {
  const directory = process.argv[2];
  assert.ok(directory !== undefined, "Expected the deployed footer directory");
  await check(directory);
} catch (error) {
  console.error(error);
  process.exitCode = 1;
}
