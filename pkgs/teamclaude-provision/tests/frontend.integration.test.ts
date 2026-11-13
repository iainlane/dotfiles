import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, inject, it } from "vitest";

const { frontend } = inject("launchers");
const anyString: unknown = expect.any(String);

async function resultFile(path: string): Promise<unknown> {
  try {
    const decoded: unknown = JSON.parse(await readFile(path, "utf8"));

    return decoded;
  } catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") {
      return null;
    }

    throw error;
  }
}

describe.skipIf(frontend.length === 0)("Frontend launcher", () => {
  it.each([0, 1])(
    "requires a successful frontend health check: %s",
    async (status) => {
      const directory = await mkdtemp(
        join(tmpdir(), "teamclaude-frontend-launcher-"),
      );
      const claudeResult = join(directory, "claude.json");
      const frontendResult = join(directory, "frontend.json");

      try {
        const result = spawnSync(frontend, ["--print", "hello world"], {
          env: {
            PATH: "",
            FRONTEND_STATUS: String(status),
            FRONTEND_RESULT: frontendResult,
            CLAUDE_RESULT: claudeResult,
            ANTHROPIC_BASE_URL: "http://wrong.invalid",
          },
          encoding: "utf8",
          timeout: 10000,
        });

        expect({
          status: result.status,
          stdout: result.stdout,
          stderr: result.stderr,
          frontend: await resultFile(frontendResult),
          claude: await resultFile(claudeResult),
        }).toStrictEqual({
          status,
          stdout: "",
          stderr: status === 0 ? "" : anyString,
          frontend: ["check", "--config", "/fixture/frontend.json"],
          claude:
            status === 0
              ? {
                  args: ["--print", "hello world"],
                  env: {
                    HTTPS_PROXY: "http://127.0.0.1:3457",
                    HTTP_PROXY: "http://127.0.0.1:3457",
                    https_proxy: "http://127.0.0.1:3457",
                    http_proxy: "http://127.0.0.1:3457",
                    NO_PROXY: "127.0.0.1,localhost",
                    no_proxy: "127.0.0.1,localhost",
                    NODE_EXTRA_CA_CERTS: "/fixture/authority/ca.pem",
                    ANTHROPIC_BASE_URL: null,
                  },
                }
              : null,
        });
      } finally {
        await rm(directory, { recursive: true, force: true });
      }
    },
  );
});
