import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { expect, it } from "vitest";
import { z } from "zod";
import { hostManifestSchema } from "@dotfiles/librechat-runtime/manifest";

const execute = promisify(execFile);
const stringMatcher: unknown = expect.any(String);
const redactedTextMatcher: unknown = expect.stringContaining("[redacted]");

function digest(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

it.each([
  { code: 0, stdoutClosed: false, status: 0 },
  { code: 1, stdoutClosed: false, status: 1 },
  { code: 0, stdoutClosed: true, status: 1 },
])(
  "flushes output with exit code $code and stdout closed: $stdoutClosed",
  async ({ code, stdoutClosed, status: expectedStatus }) => {
    const directory = await mkdtemp(join(tmpdir(), "librechat-output-"));
    const entry = join(directory, "output.mjs");
    const stdout = stdoutClosed
      ? ""
      : `${"output ".repeat(256 * 1024)}final stdout\n`;
    const stderr = `${"error ".repeat(256 * 1024)}final stderr\n`;

    await writeFile(
      entry,
      `
    import { exitAfterFlushing } from ${JSON.stringify(import.meta.resolve("#cli/presentation/output"))};

    if (${stdoutClosed}) {
      process.stdout.on("error", () => {});
      process.stdout.end();
    } else {
      process.stdout.write("output ".repeat(256 * 1024) + "final stdout\\n");
    }
    process.stderr.write("error ".repeat(256 * 1024) + "final stderr\\n");
    setInterval(() => {}, 60_000);
    try {
      await exitAfterFlushing(${code});
    } catch {
      process.exitCode = 1;
    }
  `,
    );

    try {
      let status: number | null = 0;
      let output: { stdout: string; stderr: string };

      try {
        output = await execute(process.execPath, [entry], {
          timeout: 10_000,
          maxBuffer: 8 * 1024 * 1024,
        });
      } catch (error) {
        const failure = z
          .object({
            code: z.number().nullable(),
            stdout: z.string(),
            stderr: z.string(),
          })
          .parse(error);
        status = failure.code;
        output = failure;
      }

      expect({
        status,
        stdout: digest(output.stdout),
        stderr: digest(output.stderr),
      }).toStrictEqual({
        status: expectedStatus,
        stdout: digest(stdout),
        stderr: digest(stderr),
      });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  },
  15_000,
);

it("keeps the logger configured for HTTP handlers after command startup returns", async () => {
  const directory = await mkdtemp(join(tmpdir(), "librechat-logger-"));
  const entry = join(directory, "logger.mjs");
  await writeFile(
    entry,
    `
      import { createServer } from "node:http";
      import { once } from "node:events";
      import { main } from ${JSON.stringify(import.meta.resolve("#cli/application/runtime"))};
      import { getLogger } from ${JSON.stringify(import.meta.resolve("@logtape/logtape"))};

      const request = globalThis.fetch;
      let logger;
      globalThis.fetch = async () => {
        logger = getLogger(["librechat"]).with({ service: "guest" });
        return Response.json({ archive: true });
      };
      const server = createServer((_request, response) => {
        logger.error("Guest operation failed", { event: "late-guest-error" });
        response.end();
      });
      server.listen(0, "127.0.0.1");
      await once(server, "listening");
      try {
        await main(["archive", "session", "search", "concept"]);
        const response = await request("http://127.0.0.1:" + server.address().port);
        await response.body?.cancel();
      } finally {
        await new Promise((resolve) => server.close(resolve));
      }
    `,
  );
  try {
    const { stdout, stderr } = await execute(process.execPath, [entry], {
      env: { AGENTSVIEW_BROKER_TOKEN: "fixture-archive-token" },
      timeout: 10_000,
    });
    const diagnostics: unknown = JSON.parse(stderr);
    expect({ stdout, diagnostics }).toStrictEqual({
      stdout: '{"archive":true}',
      diagnostics: {
        "@timestamp": stringMatcher,
        level: "ERROR",
        logger: "librechat",
        message: "Guest operation failed",
        service: "guest",
        event: "late-guest-error",
      },
    });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

it("redacts file-backed host credentials from failures reaching the CLI reporter", async () => {
  const directory = await mkdtemp(join(tmpdir(), "librechat-host-error-"));
  const secret = "file-key-value";
  const secretDirectory = join(directory, "secrets");
  await mkdir(secretDirectory);
  await writeFile(join(secretDirectory, "mongodb"), secret);
  await writeFile(join(secretDirectory, "code-auth.json"), secret);
  const manifest = hostManifestSchema.parse({
    stateDirectory: directory,
    socketDirectory: join(directory, "sockets"),
    homeDirectory: directory,
    hookCommand: "",
    skillsDirectory: directory,
    instructions: "",
    chatPrompt: "Fixture",
    models: { anthropic: "", openai: "", openrouter: "", ollama: "" },
    providers: {
      ollamaUrl: null,
      openaiKeyFile: null,
      anthropicKeyFile: null,
      openrouterKeyFile: null,
    },
    mcpServers: {},
    localMcpServers: [],
    mcpHeaderFiles: {},
    programs: Object.fromEntries(
      hostManifestSchema.shape.programs
        .keyof()
        .options.map((program) => [program, "/unused"]),
    ),
    guest: {
      image: "/unused",
      kernel: "/unused",
      initrd: "/unused",
      init: "/unused",
      architecture: "aarch64",
      accelerator: "tcg",
    },
  });
  const file = join(directory, "manifest.json");
  await writeFile(file, JSON.stringify(manifest));
  try {
    let failure: unknown;
    try {
      await execute(
        process.execPath,
        [
          fileURLToPath(import.meta.resolve("#cli/bin/librechat-runtime")),
          "serve",
          file,
        ],
        { env: {}, timeout: 10_000 },
      );
    } catch (error) {
      failure = error;
    }
    const output = z
      .object({ code: z.number(), stdout: z.string(), stderr: z.string() })
      .parse(failure);
    const [first, ...messages] = output.stderr.trimEnd().split("\n");
    const diagnostic: unknown = JSON.parse(first ?? "");
    expect({
      status: output.code,
      stdout: output.stdout,
      containsSecret: output.stderr.includes(secret),
      diagnostics: [diagnostic, ...messages],
    }).toStrictEqual({
      status: 1,
      stdout: "",
      containsSecret: false,
      diagnostics: [
        {
          "@timestamp": stringMatcher,
          level: "ERROR",
          logger: "librechat",
          message: "LibreChat operation failed",
          entryPoint: "runtime",
          command: "serve",
          event: "librechat-service-error",
          error: {
            name: "HostStartupError",
            message:
              "Could not start the LibreChat host services. Check the service logs.",
            stack: stringMatcher,
            cause: {
              name: "SyntaxError",
              message: redactedTextMatcher,
              stack: stringMatcher,
            },
          },
        },
        "Error: Could not start the LibreChat host services. Check the service logs.",
      ],
    });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

it("runs archive queries without host deployment dependencies", async () => {
  const directory = await mkdtemp(join(tmpdir(), "librechat-cli-"));

  const preload = join(directory, "fetch.mjs");

  const token = "a".repeat(64);

  await writeFile(
    preload,
    `globalThis.fetch = async (url, options) => Response.json({
      url,
      headers: options.headers,
      query: JSON.parse(options.body),
    });`,
  );

  try {
    const { stdout, stderr } = await execute(
      process.execPath,
      [
        "--import",
        pathToFileURL(preload).href,
        fileURLToPath(import.meta.resolve("#cli/bin/librechat-runtime")),
        "archive",
        "session",
        "search",
        "concept",
        "--limit",
        "1",
      ],
      { env: { AGENTSVIEW_BROKER_TOKEN: token }, cwd: directory },
    );

    const response: unknown = JSON.parse(stdout);

    expect({ response, stderr }).toStrictEqual({
      response: {
        url: "http://10.0.2.102:3194/query",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        query: ["session", "search", "--json", "--limit", "1", "--", "concept"],
      },
      stderr: "",
    });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
