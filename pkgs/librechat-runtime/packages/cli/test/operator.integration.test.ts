import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { afterEach, expect, it } from "vitest";
import { parseCommand } from "#cli/definitions/commands";
import { runProcess, type ProcessResult } from "./processes.ts";

const directories: string[] = [];
afterEach(async () => {
  await Promise.all(
    directories
      .splice(0)
      .map(async (root) => await rm(root, { recursive: true, force: true })),
  );
});

async function directory(): Promise<string> {
  const result = await mkdtemp(join(tmpdir(), "librechat-operator-"));
  directories.push(result);
  return result;
}

async function run(
  args: string[],
  options: {
    entry?: "public" | "runtime";
    preload?: string;
    ci?: string;
    input?: string;
  } = {},
): Promise<ProcessResult> {
  const entry =
    options.entry === "runtime" ? "librechat-runtime" : "librechatctl";
  return await runProcess(
    process.execPath,
    [
      ...(options.preload === undefined
        ? []
        : ["--import", pathToFileURL(options.preload).href]),
      fileURLToPath(import.meta.resolve(`#cli/bin/${entry}`)),
      ...args,
    ],
    {
      cwd: tmpdir(),
      env: {
        ...process.env,
        CI: options.ci,
        LIBRECHAT_INTERNAL_MANIFEST: "/nonexistent/librechat-deployment.json",
      },
      input: options.input,
    },
  );
}

it.each([
  { args: [] },
  { args: ["--help"] },
  { args: ["bootstrap", "--help"] },
  { args: ["--version"] },
])(
  "prints public help and version without deployment access: $args",
  async ({ args }) => {
    const intent = parseCommand(args, "public");
    expect(await run(args)).toStrictEqual({
      status: 0,
      stdout:
        intent.kind === "help" || intent.kind === "version"
          ? `${intent.text}\n`
          : intent,
      stderr: "",
    });
  },
);

it.each([
  {
    option: "--name",
    value: "ab",
    message: "Use --name with a display name of 3 to 80 characters.",
  },
  {
    option: "--email",
    value: "invalid",
    message: "Use a valid email address for --email.",
  },
  {
    option: "--password-file",
    value: "",
    message: "Use --password-file with a non-empty file path.",
  },
])(
  "explains invalid $option without deployment access",
  async ({ option, value, message }) => {
    expect(await run(["bootstrap", option, value])).toStrictEqual({
      status: 2,
      stdout: "",
      stderr: `Error: Invalid arguments. ${message} Run librechatctl bootstrap --help for usage.\n`,
    });
  },
);

it.each([
  { stdinTTY: false, stderrTTY: true, ci: undefined },
  { stdinTTY: true, stderrTTY: false, ci: undefined },
  { stdinTTY: true, stderrTTY: true, ci: "1" },
])(
  "does not prompt with piped input or CI: %j",
  async ({ stdinTTY, stderrTTY, ci }) => {
    const root = await directory();
    const preload = join(root, "terminal.mjs");
    await writeFile(
      preload,
      `
    Object.defineProperty(process.stdin, "isTTY", { value: ${stdinTTY} });
    Object.defineProperty(process.stderr, "isTTY", { value: ${stderrTTY} });
  `,
    );
    expect(
      await run(["--yes", "bootstrap"], {
        preload,
        ci,
        input: "not prompt answers\n",
      }),
    ).toStrictEqual({
      status: 2,
      stdout: "",
      stderr:
        "Error: Non-interactive bootstrap requires --email and --name.\nFor a new account, also provide --password-file. Run in a terminal to enter these values interactively.\n",
    });
  },
);

it("keeps hook stdin and stdout exclusively for the protocol with --yes", async () => {
  const root = await directory();
  const token = "a".repeat(64);
  const tokenFile = join(root, "token");
  const configuration = join(root, "hook.json");
  const preload = join(root, "fetch.mjs");
  const conversation = "00000000-0000-4000-8000-000000000001";
  await writeFile(tokenFile, token);
  await writeFile(
    configuration,
    JSON.stringify({ tokenFile, baseURL: "http://127.0.0.1:3193" }),
  );
  await writeFile(
    preload,
    `globalThis.fetch = async (url, options) => Response.json({
    additionalContext: JSON.stringify({ url, headers: options.headers, body: JSON.parse(options.body) }),
  });`,
  );
  expect(
    await run(["--yes", "hook", configuration, "--yes"], {
      entry: "runtime",
      preload,
      input: JSON.stringify({ session_id: conversation }),
    }),
  ).toStrictEqual({
    status: 0,
    stderr: "",
    stdout: `${JSON.stringify({
      additionalContext: JSON.stringify({
        url: "http://127.0.0.1:3193/activity",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: { conversationId: conversation },
      }),
    })}\n`,
  });
});
