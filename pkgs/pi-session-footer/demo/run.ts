import { spawn } from "node:child_process";
import { constants } from "node:os";
import { parseArgs } from "node:util";
import { demoFixture } from "./fixture.ts";
import { DemoProvider } from "./provider.ts";
import { DemoWorkspace } from "./workspace.ts";

async function run(workspace: DemoWorkspace): Promise<number> {
  const [host, ...args] = workspace.command(process.env.PI_TEST_HOST ?? "pi");
  if (host === undefined) {
    throw new Error("Expected a native Pi executable");
  }
  const child = spawn(host, args, {
    cwd: workspace.cwd,
    env: workspace.env,
    stdio: "inherit",
  });
  const ended = Promise.withResolvers<{ code: number; error?: Error }>();
  child.once("error", (error) => ended.resolve({ code: 1, error }));
  child.once("close", (code, signal) => {
    ended.resolve({
      code:
        signal === null ? (code ?? 1) : 128 + (constants.signals[signal] ?? 0),
    });
  });
  let timeout: ReturnType<typeof setTimeout> | undefined;
  const stop = () => {
    if (
      child.pid === undefined ||
      child.exitCode !== null ||
      child.signalCode !== null
    ) {
      return;
    }
    child.kill("SIGTERM");
    timeout ??= setTimeout(() => child.kill("SIGKILL"), 5000);
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
  try {
    const result = await ended.promise;
    if (result.error !== undefined) {
      throw new Error(
        "Cannot start Pi. Set PI_TEST_HOST to the native Pi executable.",
        { cause: result.error },
      );
    }
    return result.code;
  } finally {
    process.off("SIGTERM", stop);
    process.off("SIGINT", stop);
    clearTimeout(timeout);
  }
}

async function main(): Promise<void> {
  const { values } = parseArgs({
    options: {
      preset: { type: "string", default: "rich" },
      theme: { type: "string", default: "dark" },
      help: { type: "boolean", short: "h" },
    },
  });
  if (values.help === true) {
    console.log(
      "node demo/run.ts [--preset rich|compact|minimal|workflow] [--theme dark|light]",
    );
    return;
  }
  const preset = values.preset;
  if (
    preset !== "rich" &&
    preset !== "compact" &&
    preset !== "minimal" &&
    preset !== "workflow"
  ) {
    throw new Error("Expected --preset rich, compact, minimal or workflow");
  }
  const theme = values.theme;
  if (theme !== "dark" && theme !== "light") {
    throw new Error("Expected --theme dark or --theme light");
  }
  const workspace = DemoWorkspace.create(demoFixture);
  try {
    const provider = await DemoProvider.start(demoFixture);
    try {
      workspace.configure(provider.url, { preset, theme });
      process.exitCode = await run(workspace);
    } finally {
      await provider.close();
    }
  } finally {
    workspace.close();
  }
}

try {
  await main();
} catch (error) {
  console.error(error);
  process.exitCode = 1;
}
