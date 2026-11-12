import { execFile, type ExecFileException } from "node:child_process";
import { readFileSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { expect, it, onTestFinished } from "vitest";
import { demoFixture } from "#demo/fixture.ts";
import { DemoProvider } from "#demo/provider.ts";
import { DemoWorkspace } from "#demo/workspace.ts";

it.for([
  {
    args: ["--help"],
    status: 0,
    stdout:
      "node demo/run.ts [--preset rich|compact|minimal|workflow] [--theme dark|light]",
    error: "",
  },
  {
    args: ["--preset", "unknown"],
    status: 1,
    stdout: "",
    error: "Error: Expected --preset rich, compact, minimal or workflow",
  },
  {
    args: ["--theme", "unknown"],
    status: 1,
    stdout: "",
    error: "Error: Expected --theme dark or --theme light",
  },
])(
  "runs the plain Node CLI for $args",
  async ({ args, ...expected }, { signal }) => {
    const result = await promisify(execFile)(
      process.execPath,
      ["demo/run.ts", ...args],
      {
        cwd: fileURLToPath(new URL("../../", import.meta.url)),
        env: { ...process.env, NODE_OPTIONS: "" },
        encoding: "utf8",
        signal,
      },
    ).then(
      ({ stdout, stderr }) => ({ status: 0, stdout, stderr }),
      (error: ExecFileException & { stdout: string; stderr: string }) => ({
        status: error.code,
        stdout: error.stdout,
        stderr: error.stderr,
      }),
    );
    expect({
      status: result.status,
      stdout: result.stdout.trimEnd(),
      error: result.stderr.split("\n")[0],
    }).toStrictEqual(expected);
  },
);

it("streams the selected fixture's response and usage", async () => {
  const fixture = {
    ...demoFixture,
    model: { ...demoFixture.model, id: "edited-model" },
    response: [{ atMs: 0, text: "Edited response" }],
    usage: { promptTokens: 200, cachedTokens: 100, outputTokens: 3 },
  };
  const provider = await DemoProvider.start(fixture);
  onTestFinished(() => provider.close());
  const response = await fetch(`${provider.url}/chat/completions`, {
    method: "POST",
    body: JSON.stringify({ model: fixture.model.id }),
  });
  const events = (await response.text())
    .split("\n\n")
    .filter(Boolean)
    .map((line) => line.slice(6));
  expect({ status: response.status, events }).toStrictEqual({
    status: 200,
    events: [
      JSON.stringify({
        id: "footer-demo",
        object: "chat.completion.chunk",
        model: "edited-model",
        choices: [
          {
            index: 0,
            delta: { role: "assistant", content: "Edited response" },
            finish_reason: null,
          },
        ],
      }),
      JSON.stringify({
        id: "footer-demo",
        object: "chat.completion.chunk",
        model: "edited-model",
        choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
        usage: {
          prompt_tokens: 200,
          completion_tokens: 3,
          total_tokens: 203,
          prompt_tokens_details: { cached_tokens: 100 },
        },
      }),
      "[DONE]",
    ],
  });
});

it.each([
  { description: "GET", options: { method: "GET" }, status: 404 },
  {
    description: "malformed JSON",
    options: { method: "POST", body: "{" },
    status: 400,
  },
  {
    description: "wrong model",
    options: { method: "POST", body: '{"model":"other"}' },
    status: 400,
  },
])(
  "rejects invalid scripted requests: $description",
  async ({ options, status }) => {
    const provider = await DemoProvider.start(demoFixture);
    onTestFinished(() => provider.close());
    const response = await fetch(`${provider.url}/chat/completions`, options);
    expect(response.status).toBe(status);
  },
);

it("creates a private fixture workspace and loads only this extension", () => {
  const workspace = DemoWorkspace.create(demoFixture);
  onTestFinished(() => workspace.close());
  workspace.configure("http://127.0.0.1:12345/v1", {
    preset: "minimal",
    theme: "light",
  });
  const extension = fileURLToPath(
    new URL(import.meta.resolve("#footer-entry")),
  );
  const footer: unknown = JSON.parse(
    readFileSync(join(workspace.agent, "session-footer.json"), "utf8"),
  );
  expect({
    footer,
    home: workspace.env.HOME,
    command: workspace.command("pi"),
    environment: Object.keys(workspace.env).toSorted(),
  }).toStrictEqual({
    footer: { preset: "minimal" },
    home: realpathSync(join(workspace.cwd, "..")),
    command: [
      "pi",
      "--offline",
      "--no-extensions",
      "-e",
      extension,
      "--no-mcp",
      "--no-skills",
      "--no-context-files",
      "--no-prompt-templates",
      "--no-tools",
      "--tui-mode",
      "fullscreen",
      "--provider",
      demoFixture.model.provider,
      "--model",
      demoFixture.model.id,
      "--thinking",
      "high",
    ],
    environment: [
      "PATH",
      "HOME",
      "XDG_CONFIG_HOME",
      "XDG_CACHE_HOME",
      "XDG_STATE_HOME",
      "PI_CODING_AGENT_DIR",
      "PI_OFFLINE",
      "GIT_CONFIG_NOSYSTEM",
      "TERM",
      "COLORTERM",
      "LANG",
    ].toSorted(),
  });
});
