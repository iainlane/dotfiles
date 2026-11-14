import type { Logger } from "@logtape/logtape";
import { expect, it } from "vitest";
import { runCommand } from "#cli/application/dispatch";
import type {
  CommandDependencies,
  Deployment,
  RuntimeServices,
} from "#cli/application/ports";
import { ErrorReporter } from "#cli/presentation/errors";
import { testLogger } from "./logging.ts";
import { FakeAccounts, FakeFiles, FakeTerminal } from "./fakes.ts";

class DeploymentFileMissingError extends Error {
  constructor(file: string) {
    super(`No deployment manifest at ${file}`);
    this.name = "DeploymentFileMissingError";
  }
}

class FakeDeployment implements Deployment {
  readonly accounts: FakeAccounts;
  readonly url = "http://127.0.0.1:3080";
  readonly workspaces: Set<string>;

  constructor(accounts: FakeAccounts, workspaces: string[] = []) {
    this.accounts = accounts;
    this.workspaces = new Set(workspaces);
  }

  async resetWorkspace(conversation: string): Promise<void> {
    this.workspaces.delete(conversation);
  }
}

const services: RuntimeServices = {
  serve: async () => {},
  guest: async () => {},
  hook: async () => {},
  archive: async () => '{"archive":true}\n\n',
};

/**
 * Reports diagnostics as the CLI does: service failures always include
 * structured diagnostics, and command failures include them only on request.
 */
function diagnostics(logger: Logger): CommandDependencies["reportDiagnostics"] {
  const output = { logger, secrets: [], write: () => {} };
  const reporters = {
    service: new ErrorReporter({ ...output, diagnostics: true }),
    command: new ErrorReporter({ ...output, diagnostics: false }),
  };
  return (error, service, commandLogger) => {
    reporters[service ? "service" : "command"].diagnose(error, commandLogger);
  };
}

function fixture(
  options: {
    deployment?: FakeDeployment;
    terminal?: FakeTerminal;
    services?: Partial<RuntimeServices>;
  } = {},
) {
  const presentation =
    options.terminal ?? new FakeTerminal({ interactive: false });
  const stdout: string[] = [];
  const logs: string[] = [];
  const logger = testLogger((text) => logs.push(text));
  const dependencies = {
    logger,
    manifest: "/manifest.json",
    presentation,
    services: { ...services, ...options.services },
    files: new FakeFiles(),
    openDeployment: async (file: string): Promise<Deployment> => {
      if (options.deployment === undefined || file !== "/manifest.json") {
        throw new DeploymentFileMissingError(file);
      }
      return options.deployment;
    },
    writeOutput: (text: string) => {
      stdout.push(text);
    },
    reportDiagnostics: diagnostics(logger),
  } satisfies CommandDependencies;
  return {
    dependencies,
    screen: presentation.screen,
    output: () => stdout.join(""),
    logs: () => logs.map((line): unknown => JSON.parse(line)),
  };
}

it.each([[], ["--help"], ["--version"], ["bootstrap", "--help"]])(
  "does not open the deployment for informational commands: %j",
  async (...args) => {
    const { dependencies, screen } = fixture({ terminal: new FakeTerminal() });
    const result = await runCommand(args, "public", dependencies);
    expect({ result, screen }).toStrictEqual({
      result: { status: 0, forceExit: false },
      screen: [],
    });
  },
);

it("rejects invalid supplied values before deployment access", async () => {
  const { dependencies, screen, output } = fixture();
  const result = await runCommand(
    ["bootstrap", "--email", "invalid"],
    "public",
    dependencies,
  );
  expect({ result, output: output(), screen }).toStrictEqual({
    result: { status: 2, forceExit: false },
    output: "",
    screen: [
      "Error: Invalid arguments. Use a valid email address for --email. Run librechatctl bootstrap --help for usage.",
    ],
  });
});

it("preserves the exact plain bootstrap completion line", async () => {
  const accounts = new FakeAccounts({
    accounts: { "you@example.com": { name: "Old Name" } },
  });
  const { dependencies, output } = fixture({
    deployment: new FakeDeployment(accounts),
  });
  const result = await runCommand(
    ["bootstrap", "--email", "you@example.com", "--name", "Your Name"],
    "public",
    dependencies,
  );
  expect({
    result,
    accounts: [...accounts.accounts],
    output: output(),
  }).toStrictEqual({
    result: { status: 0, forceExit: true },
    accounts: [["you@example.com", { name: "Your Name" }]],
    output: "LibreChat account bootstrap completed.\n",
  });
});

it("does not expose native error messages or claim success on failure", async () => {
  const { dependencies, screen, output } = fixture({
    deployment: new FakeDeployment(
      new FakeAccounts({
        failure: new Error("mongodb://private:password@example.com"),
      }),
    ),
  });
  const result = await runCommand(
    ["bootstrap", "--email", "you@example.com", "--name", "Your Name"],
    "public",
    dependencies,
  );
  expect({ result, output: output(), screen }).toStrictEqual({
    result: { status: 1, forceExit: true },
    output: "",
    screen: [
      "Error: Could not bootstrap LibreChat. Check that the LibreChat services are running and consult their logs.",
    ],
  });
});

const conversation = "00000000-0000-4000-8000-000000000001";

it("does not contact the deployment after workspace deletion is declined", async () => {
  const { dependencies, screen } = fixture({ terminal: new FakeTerminal() });
  const result = await runCommand(
    ["reset", "--conversation", conversation],
    "public",
    dependencies,
  );
  expect({ result, screen }).toStrictEqual({
    result: { status: 130, forceExit: false },
    screen: [
      "┌ Reset conversation workspace",
      "? Delete this workspace, including unpushed work? (y/N)",
      "Cancelled. No changes were made.",
    ],
  });
});

it.each(["public", "runtime"] as const)(
  "preserves the %s workspace-reset output contract",
  async (entry) => {
    const deployment = new FakeDeployment(new FakeAccounts(), [conversation]);
    const { dependencies, screen, output } = fixture({ deployment });
    const args = entry === "public" ? ["reset"] : ["reset", "/manifest.json"];
    const result = await runCommand(
      [...args, "--conversation", conversation, "--yes"],
      entry,
      dependencies,
    );
    expect({
      result,
      workspaces: [...deployment.workspaces],
      output: output(),
      screen,
    }).toStrictEqual({
      result: { status: 0, forceExit: false },
      workspaces: [],
      output: entry === "public" ? "Workspace deleted.\n" : "",
      screen: [],
    });
  },
);

it("forwards archive response bytes without presentation", async () => {
  const { dependencies, screen, output } = fixture({
    terminal: new FakeTerminal(),
  });
  const result = await runCommand(
    ["archive", "session", "search", "concept"],
    "runtime",
    dependencies,
  );
  expect({ result, output: output(), screen }).toStrictEqual({
    result: { status: 0, forceExit: false },
    output: '{"archive":true}\n\n',
    screen: [],
  });
});

it("threads command child loggers into service operations without changing the parent context", async () => {
  const { dependencies, logs } = fixture({
    services: {
      guest: async (_file, logger) => {
        logger.info("Guest starting", { event: "guest-start" });
      },
    },
  });
  const result = await runCommand(
    ["guest", "/spec.json"],
    "runtime",
    dependencies,
  );
  dependencies.logger.info("Command returned", { event: "command-returned" });
  expect({ result, logs: logs() }).toStrictEqual({
    result: { status: 0, forceExit: false },
    logs: [
      {
        "@timestamp": "1970-01-01T00:00:00.000Z",
        level: "INFO",
        logger: "librechat",
        message: "Guest starting",
        entryPoint: "runtime",
        command: "guest",
        event: "guest-start",
      },
      {
        "@timestamp": "1970-01-01T00:00:00.000Z",
        level: "INFO",
        logger: "librechat",
        message: "Command returned",
        entryPoint: "runtime",
        event: "command-returned",
      },
    ],
  });
});

it.each(["serve", "guest", "hook"] as const)(
  "reports the original %s failure as a service or command diagnostic",
  async (command) => {
    const failure = Object.assign(new Error("startup failed"), {
      stack: undefined,
      cause: Object.assign(new Error("spawn failed"), {
        stack: undefined,
        code: "ENOENT",
      }),
    });
    const { dependencies, screen, logs } = fixture({
      services: {
        [command]: async () => {
          throw failure;
        },
      },
    });
    const result = await runCommand(
      [command, "/spec.json"],
      "runtime",
      dependencies,
    );
    expect({ result, screen, logs: logs() }).toStrictEqual({
      result: { status: 1, forceExit: false },
      screen: ["Error: LibreChat command failed. Check the service logs."],
      logs:
        command === "hook"
          ? []
          : [
              {
                "@timestamp": "1970-01-01T00:00:00.000Z",
                level: "ERROR",
                logger: "librechat",
                message: "LibreChat operation failed",
                entryPoint: "runtime",
                command,
                event: "librechat-service-error",
                error: {
                  name: "Error",
                  message: "startup failed",
                  cause: {
                    name: "Error",
                    message: "spawn failed",
                    code: "ENOENT",
                  },
                },
              },
            ],
    });
  },
);
