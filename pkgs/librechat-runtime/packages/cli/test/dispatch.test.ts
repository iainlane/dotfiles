import { expect, it, vi } from "vitest";
import { runCommand } from "#cli/application/dispatch";
import { RuntimeErrorPolicy } from "#cli/application/runtime";
import type {
  AccountAccess,
  CommandDependencies,
  Presentation,
  RuntimeServices,
} from "#cli/application/ports";

function fixture() {
  const accounts = {
    binding: vi.fn<AccountAccess["binding"]>().mockResolvedValue(null),
    inspect: vi
      .fn<AccountAccess["inspect"]>()
      .mockResolvedValue({ exists: true, name: "Your Name" }),
    passwordIssue: vi.fn<AccountAccess["passwordIssue"]>(),
    bootstrap: vi.fn<AccountAccess["bootstrap"]>().mockResolvedValue(undefined),
  };
  const presentation = {
    interactive: false,
    text: vi.fn<Presentation["text"]>(),
    password: vi.fn<Presentation["password"]>(),
    confirm: vi.fn<Presentation["confirm"]>(),
    intro: vi.fn<Presentation["intro"]>(),
    info: vi.fn<Presentation["info"]>(),
    success: vi.fn<Presentation["success"]>(),
    outro: vi.fn<Presentation["outro"]>(),
    error: vi.fn<Presentation["error"]>(),
    cancel: vi.fn<Presentation["cancel"]>(),
    progress: async <T>(
      _message: string,
      operation: () => Promise<T>,
    ): Promise<T> => await operation(),
  };
  const services = {
    serve: vi.fn<RuntimeServices["serve"]>(),
    guest: vi.fn<RuntimeServices["guest"]>(),
    hook: vi.fn<RuntimeServices["hook"]>(),
    archive: vi
      .fn<RuntimeServices["archive"]>()
      .mockResolvedValue('{"archive":true}\n\n'),
  };
  const resetWorkspace = vi
    .fn<(conversation: string) => Promise<void>>()
    .mockResolvedValue(undefined);
  const dependencies = {
    manifest: "/manifest.json",
    presentation,
    services,
    files: { readText: vi.fn<CommandDependencies["files"]["readText"]>() },
    openDeployment: vi
      .fn<CommandDependencies["openDeployment"]>()
      .mockResolvedValue({
        accounts,
        url: "http://127.0.0.1:3080",
        resetWorkspace,
      }),
    writeOutput: vi.fn<CommandDependencies["writeOutput"]>(),
    reportDiagnostics: vi.fn<CommandDependencies["reportDiagnostics"]>(),
  } satisfies CommandDependencies;
  return { dependencies, resetWorkspace, accounts };
}

it.each([[], ["--help"], ["--version"], ["bootstrap", "--help"]])(
  "does not open the deployment for informational commands: %j",
  async (...args) => {
    const { dependencies, accounts } = fixture();
    const result = await runCommand(args, "public", dependencies);
    expect({
      result,
      deployment: dependencies.openDeployment.mock.calls,
      bootstrap: accounts.bootstrap.mock.calls,
      intro: dependencies.presentation.intro.mock.calls,
    }).toStrictEqual({
      result: { status: 0, forceExit: false },
      deployment: [],
      bootstrap: [],
      intro: [],
    });
  },
);

it("rejects invalid supplied values before deployment access", async () => {
  const { dependencies } = fixture();
  const result = await runCommand(
    ["bootstrap", "--email", "invalid"],
    "public",
    dependencies,
  );
  expect({
    result,
    deployment: dependencies.openDeployment.mock.calls,
    output: dependencies.writeOutput.mock.calls,
    errors: dependencies.presentation.error.mock.calls,
  }).toStrictEqual({
    result: { status: 2, forceExit: false },
    deployment: [],
    output: [],
    errors: [
      [
        "Invalid arguments. Use a valid email address for --email. Run librechatctl bootstrap --help for usage.",
      ],
    ],
  });
});

it("preserves the exact plain bootstrap completion line", async () => {
  const { dependencies, accounts } = fixture();
  const result = await runCommand(
    ["bootstrap", "--email", "you@example.com", "--name", "Your Name"],
    "public",
    dependencies,
  );
  expect({
    result,
    bootstrap: accounts.bootstrap.mock.calls,
    output: dependencies.writeOutput.mock.calls,
  }).toStrictEqual({
    result: { status: 0, forceExit: true },
    bootstrap: [
      [{ email: "you@example.com", name: "Your Name", password: undefined }],
    ],
    output: [["LibreChat account bootstrap completed.\n"]],
  });
});

it("does not expose native error messages or claim success on failure", async () => {
  const { dependencies, accounts } = fixture();
  accounts.bootstrap.mockRejectedValue(
    new Error("mongodb://private:password@example.com"),
  );
  const result = await runCommand(
    ["bootstrap", "--email", "you@example.com", "--name", "Your Name"],
    "public",
    dependencies,
  );
  expect({
    result,
    output: dependencies.writeOutput.mock.calls,
    errors: dependencies.presentation.error.mock.calls,
  }).toStrictEqual({
    result: { status: 1, forceExit: true },
    output: [],
    errors: [
      [
        "Could not bootstrap LibreChat. Check that the LibreChat services are running and consult their logs.",
      ],
    ],
  });
});

const conversation = "00000000-0000-4000-8000-000000000001";

it("does not contact the deployment after workspace deletion is declined", async () => {
  const { dependencies, resetWorkspace } = fixture();
  dependencies.presentation.interactive = true;
  dependencies.presentation.confirm.mockResolvedValue(false);
  const result = await runCommand(
    ["reset", "--conversation", conversation],
    "public",
    dependencies,
  );
  expect({
    result,
    deployment: dependencies.openDeployment.mock.calls,
    reset: resetWorkspace.mock.calls,
    cancellation: dependencies.presentation.cancel.mock.calls,
  }).toStrictEqual({
    result: { status: 130, forceExit: false },
    deployment: [],
    reset: [],
    cancellation: [["Cancelled. No changes were made."]],
  });
});

it.each(["public", "runtime"] as const)(
  "preserves the %s workspace-reset output contract",
  async (entry) => {
    const { dependencies, resetWorkspace } = fixture();
    const args = entry === "public" ? ["reset"] : ["reset", "/manifest.json"];
    const result = await runCommand(
      [...args, "--conversation", conversation, "--yes"],
      entry,
      dependencies,
    );
    expect({
      result,
      reset: resetWorkspace.mock.calls,
      output: dependencies.writeOutput.mock.calls,
      prompts: dependencies.presentation.confirm.mock.calls,
    }).toStrictEqual({
      result: { status: 0, forceExit: false },
      reset: [[conversation]],
      output: entry === "public" ? [["Workspace deleted.\n"]] : [],
      prompts: [],
    });
  },
);

it("forwards archive response bytes without presentation", async () => {
  const { dependencies } = fixture();
  const result = await runCommand(
    ["archive", "session", "search", "concept"],
    "runtime",
    dependencies,
  );
  expect({
    result,
    output: dependencies.writeOutput.mock.calls,
    intro: dependencies.presentation.intro.mock.calls,
    deployment: dependencies.openDeployment.mock.calls,
  }).toStrictEqual({
    result: { status: 0, forceExit: false },
    output: [['{"archive":true}\n\n']],
    intro: [],
    deployment: [],
  });
});

it("reports the original service failure through the injected diagnostic output", async () => {
  const { dependencies } = fixture();
  const cause = new TypeError("fetch failed");
  dependencies.services.guest.mockRejectedValue(cause);
  const result = await runCommand(
    ["guest", "/fixture/guest.json"],
    "runtime",
    dependencies,
  );
  expect({
    result,
    diagnostics: dependencies.reportDiagnostics.mock.calls,
    errors: dependencies.presentation.error.mock.calls,
  }).toStrictEqual({
    result: { status: 1, forceExit: false },
    diagnostics: [[cause, true]],
    errors: [["LibreChat command failed. Check the service logs."]],
  });
});

it.each(["serve", "guest", "hook"] as const)(
  "applies the composed diagnostic policy to escaping %s failures without an opt-in",
  async (command) => {
    const { dependencies } = fixture();
    const output: string[] = [];
    const errors = new RuntimeErrorPolicy({}, (text) => output.push(text));
    const failure = Object.assign(new Error("startup failed"), {
      stack: undefined,
      cause: Object.assign(new Error("spawn failed"), {
        stack: undefined,
        code: "ENOENT",
      }),
    });
    dependencies.services[command].mockRejectedValue(failure);
    const result = await runCommand([command, "/spec.json"], "runtime", {
      ...dependencies,
      reportDiagnostics: (error, service) => errors.diagnose(error, service),
    });
    expect({ result, output }).toStrictEqual({
      result: { status: 1, forceExit: false },
      output:
        command === "hook"
          ? []
          : [
              JSON.stringify({
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
              }) + "\n",
            ],
    });
  },
);
