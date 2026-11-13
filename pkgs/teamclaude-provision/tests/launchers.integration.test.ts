import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { afterEach, beforeEach, describe, expect, inject, it } from "vitest";

declare module "vitest" {
  interface ProvidedContext {
    launchers: { claude: string; server: string; frontend: string };
  }
}

const { claude, server } = inject("launchers");

describe.skipIf(!claude || !server)("TeamClaude launchers", () => {
  let directory: string;
  let configFile: string;
  let environment: NodeJS.ProcessEnv;

  beforeEach(async () => {
    directory = await mkdtemp(join(tmpdir(), "teamclaude-launchers-"));
    configFile = join(directory, ".config/teamclaude.json");
    await mkdir(join(directory, ".config"));
    environment = {
      PATH: "",
      HOME: directory,
      TEAMCLAUDE_CONFIG: configFile,
      TEAMROUTER_CONFIG: configFile,
      CLAUDE_RESULT: join(directory, "claude.json"),
      TEAMCLAUDE_RESULT: join(directory, "teamclaude.json"),
    };
  });

  afterEach(async () => {
    await rm(directory, { recursive: true, force: true });
  });

  async function runClaude() {
    const result = spawnSync(claude, ["--print", "hello world"], {
      env: environment,
      encoding: "utf8",
      timeout: 10000,
    });

    const received: unknown = JSON.parse(
      await readFile(join(directory, "claude.json"), "utf8"),
    );

    return {
      status: result.status,
      stderr: result.stderr,
      claude: received,
    };
  }

  const direct = {
    args: ["--print", "hello world"],
    httpsProxy: null,
    caFile: null,
  };

  it("starts Claude directly when the configuration is absent", async () => {
    expect(await runClaude()).toStrictEqual({
      status: 0,
      stderr: "",
      claude: direct,
    });
  });

  it("starts Claude directly when reading the proxy environment fails", async () => {
    await writeFile(configFile, "not json");

    expect(await runClaude()).toStrictEqual({
      status: 0,
      stderr:
        "claude: `teamclaude env` failed, so Claude Code is starting without the TeamClaude proxy. Run `teamclaude env` to see why.\n",
      claude: direct,
    });
  });

  it("uses a running proxy and falls back when the proxy stops", async () => {
    const listener = createServer((socket) => socket.destroy());
    await new Promise<void>((resolve, reject) => {
      listener.once("error", reject);
      listener.listen(0, "127.0.0.1", resolve);
    });

    const address = listener.address();

    if (address === null || typeof address === "string") {
      throw new Error("Expected a loopback listener address");
    }

    await writeFile(
      configFile,
      JSON.stringify({ proxy: { port: address.port }, accounts: [] }),
    );

    try {
      expect(await runClaude()).toStrictEqual({
        status: 0,
        stderr: "",
        claude: {
          args: direct.args,
          httpsProxy: `http://127.0.0.1:${address.port}`,
          caFile: join(directory, ".config/teamclaude-ca.pem"),
        },
      });
    } finally {
      await listener[Symbol.asyncDispose]();
    }

    expect(await runClaude()).toStrictEqual({
      status: 0,
      stderr:
        "claude: the TeamClaude proxy is not running, so Claude Code is starting without it. Run `teamclaude status` for details.\n",
      claude: direct,
    });
  });

  it.each([
    { config: undefined, starts: false },
    { config: { accounts: [] }, starts: false },
    {
      config: { accounts: [{ name: "personal", type: "oauth" }] },
      starts: true,
    },
  ])(
    "starts the server only after an account exists: $config",
    async ({ config, starts }) => {
      if (config) {
        await writeFile(configFile, JSON.stringify(config));
      }

      const result = spawnSync(server, [], {
        env: environment,
        encoding: "utf8",
        timeout: 10000,
      });
      const received: unknown = starts
        ? JSON.parse(await readFile(join(directory, "teamclaude.json"), "utf8"))
        : null;

      expect({
        status: result.status,
        stderr: result.stderr,
        teamclaude: received,
      }).toStrictEqual({
        status: 0,
        stderr: starts
          ? ""
          : `${configFile} lists no TeamClaude accounts. Add one with \`teamclaude login\`.\n`,
        teamclaude: starts ? ["server", "--headless"] : null,
      });
    },
  );
});
