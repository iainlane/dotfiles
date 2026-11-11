import { expect, it, vi } from "vitest";
import { CancelledError } from "#cli/application/errors";
import {
  resolveBootstrapInputs,
  resolveWorkspaceInput,
  interactiveMode,
} from "#cli/application/inputs";
import type {
  AccountAccess,
  FileAccess,
  Prompts,
} from "#cli/application/ports";
import type { BootstrapOptions } from "#cli/definitions/commands";

function fixture(interactive = true) {
  const accounts = {
    binding: vi.fn<AccountAccess["binding"]>().mockResolvedValue(null),
    inspect: vi
      .fn<AccountAccess["inspect"]>()
      .mockResolvedValue({ exists: false, name: undefined }),
    passwordIssue: vi
      .fn<AccountAccess["passwordIssue"]>()
      .mockImplementation((password) =>
        password.length < 8 ? { kind: "minimum", minimum: 8 } : undefined,
      ),
    bootstrap: vi.fn<AccountAccess["bootstrap"]>(),
  };
  const files = {
    readText: vi
      .fn<FileAccess["readText"]>()
      .mockResolvedValue("file password\n"),
  };
  const prompts = {
    interactive,
    text: vi.fn<Prompts["text"]>(),
    password: vi.fn<Prompts["password"]>(),
    confirm: vi.fn<Prompts["confirm"]>(),
  };
  return { accounts, files, prompts };
}

function options(overrides: Partial<BootstrapOptions> = {}): BootstrapOptions {
  return {
    email: undefined,
    name: undefined,
    passwordFile: undefined,
    yes: false,
    ...overrides,
  };
}

it("prefills bound account details and never reads an existing account's password file", async () => {
  const dependencies = fixture();
  dependencies.accounts.binding.mockResolvedValue({ email: "you@example.com" });
  dependencies.accounts.inspect.mockResolvedValue({
    exists: true,
    name: "Existing Name",
  });
  dependencies.prompts.text
    .mockResolvedValueOnce("you@example.com")
    .mockResolvedValueOnce("New Name");
  dependencies.files.readText.mockRejectedValue(
    new Error("Password file must not be read"),
  );

  const result = await resolveBootstrapInputs(
    options({ passwordFile: "/unreadable" }),
    dependencies,
  );

  expect({
    result,
    prompts: dependencies.prompts.text.mock.calls.map(
      ([{ message, initialValue }]) => ({ message, initialValue }),
    ),
    password: dependencies.prompts.password.mock.calls,
    files: dependencies.files.readText.mock.calls,
  }).toStrictEqual({
    result: {
      input: {
        email: "you@example.com",
        name: "New Name",
        password: undefined,
      },
      existing: true,
    },
    prompts: [
      { message: "Email address", initialValue: "you@example.com" },
      { message: "Display name", initialValue: "Existing Name" },
    ],
    password: [],
    files: [],
  });
});

it("still requests and verifies a new password with --yes", async () => {
  const dependencies = fixture();
  dependencies.prompts.password.mockResolvedValueOnce("new password");
  dependencies.prompts.password.mockImplementationOnce(async (request) => {
    expect({
      wrong: request.validate("wrong"),
      correct: request.validate("new password"),
    }).toStrictEqual({
      wrong: "The passwords did not match.",
      correct: undefined,
    });
    return "new password";
  });

  const result = await resolveBootstrapInputs(
    options({ email: "you@example.com", name: "Your Name", yes: true }),
    dependencies,
  );

  expect({
    result,
    messages: dependencies.prompts.password.mock.calls.map(
      ([request]) => request.message,
    ),
    text: dependencies.prompts.text.mock.calls,
    bootstrap: dependencies.accounts.bootstrap.mock.calls,
  }).toStrictEqual({
    result: {
      input: {
        email: "you@example.com",
        name: "Your Name",
        password: "new password",
      },
      existing: false,
    },
    messages: ["Password", "Repeat password"],
    text: [],
    bootstrap: [],
  });
});

it.each([
  { text: " password \n", password: " password " },
  { text: " password \r\n", password: " password " },
  { text: "password\n\n", password: "password\n" },
  { text: "password", password: "password" },
])(
  "preserves password-file whitespace for $text",
  async ({ text, password }) => {
    const dependencies = fixture(false);
    dependencies.files.readText.mockResolvedValue(text);
    const result = await resolveBootstrapInputs(
      options({
        email: "you@example.com",
        name: "Your Name",
        passwordFile: "/password",
      }),
      dependencies,
    );
    expect({
      result,
      prompts: dependencies.prompts.password.mock.calls,
    }).toStrictEqual({
      result: {
        input: { email: "you@example.com", name: "Your Name", password },
        existing: false,
      },
      prompts: [],
    });
  },
);

it("reports all missing non-interactive bootstrap inputs before account access", async () => {
  const dependencies = fixture(false);
  await expect(
    resolveBootstrapInputs(options({ yes: true }), dependencies),
  ).rejects.toThrow("Non-interactive bootstrap requires --email and --name.");
  expect({
    binding: dependencies.accounts.binding.mock.calls,
    inspect: dependencies.accounts.inspect.mock.calls,
    prompts: dependencies.prompts.text.mock.calls,
  }).toStrictEqual({ binding: [], inspect: [], prompts: [] });
});

it.each([true, false])(
  "requires a non-interactive password file for a new account with --yes=%s",
  async (yes) => {
    const dependencies = fixture(false);
    await expect(
      resolveBootstrapInputs(
        options({ email: "you@example.com", name: "Your Name", yes }),
        dependencies,
      ),
    ).rejects.toThrow(
      "Non-interactive bootstrap of a new account requires --password-file.",
    );
    expect(dependencies.prompts.password.mock.calls).toStrictEqual([]);
  },
);

it("does not require a password file for a non-interactive existing account", async () => {
  const dependencies = fixture(false);
  dependencies.accounts.inspect.mockResolvedValue({
    exists: true,
    name: "Existing Name",
  });
  expect(
    await resolveBootstrapInputs(
      options({ email: "you@example.com", name: "New Name" }),
      dependencies,
    ),
  ).toStrictEqual({
    input: { email: "you@example.com", name: "New Name", password: undefined },
    existing: true,
  });
});

it("does not expose password contents when validation fails", async () => {
  const dependencies = fixture(false);
  dependencies.files.readText.mockResolvedValue("secret");
  await expect(
    resolveBootstrapInputs(
      options({
        email: "you@example.com",
        name: "Your Name",
        passwordFile: "/password",
      }),
      dependencies,
    ),
  ).rejects.toThrow("Password must contain at least 8 characters.");
});

it("cancels bootstrap before provisioning", async () => {
  const dependencies = fixture();
  dependencies.prompts.text.mockRejectedValue(new CancelledError());
  await expect(resolveBootstrapInputs(options(), dependencies)).rejects.toThrow(
    CancelledError,
  );
  expect(dependencies.accounts.bootstrap.mock.calls).toStrictEqual([]);
});

const conversation = "00000000-0000-4000-8000-000000000001";

it("prompts for a workspace ID and defaults to preserving the workspace", async () => {
  const { prompts } = fixture();
  prompts.text.mockResolvedValue(conversation);
  prompts.confirm.mockResolvedValue(false);
  await expect(
    resolveWorkspaceInput({ conversation: undefined, yes: false }, prompts),
  ).rejects.toThrow(CancelledError);
  expect({
    text: prompts.text.mock.calls.map(([{ message, initialValue }]) => ({
      message,
      initialValue,
    })),
    confirm: prompts.confirm.mock.calls,
  }).toStrictEqual({
    text: [{ message: "Conversation UUID", initialValue: undefined }],
    confirm: [["Delete this workspace, including unpushed work?"]],
  });
});

it("uses --yes only for workspace confirmation", async () => {
  const { prompts } = fixture();
  prompts.text.mockResolvedValue(conversation);
  expect({
    conversation: await resolveWorkspaceInput(
      { conversation: undefined, yes: true },
      prompts,
    ),
    confirm: prompts.confirm.mock.calls,
  }).toStrictEqual({ conversation, confirm: [] });
});

it.each([
  { conversation: undefined, yes: false, missing: "--conversation and --yes" },
  { conversation, yes: false, missing: "--yes" },
  { conversation: undefined, yes: true, missing: "--conversation" },
])(
  "rejects unattended workspace reset without $missing",
  async ({ conversation: suppliedConversation, yes, missing }) => {
    const { prompts } = fixture(false);
    await expect(
      resolveWorkspaceInput(
        { conversation: suppliedConversation, yes },
        prompts,
      ),
    ).rejects.toThrow(`Non-interactive reset requires ${missing}.`);
    expect({
      text: prompts.text.mock.calls,
      confirm: prompts.confirm.mock.calls,
    }).toStrictEqual({ text: [], confirm: [] });
  },
);

it.each([
  { stdinTTY: true, stderrTTY: true, ci: undefined, interactive: true },
  { stdinTTY: false, stderrTTY: true, ci: undefined, interactive: false },
  { stdinTTY: true, stderrTTY: false, ci: undefined, interactive: false },
  { stdinTTY: true, stderrTTY: true, ci: "true", interactive: false },
  { stdinTTY: true, stderrTTY: true, ci: "1", interactive: false },
  { stdinTTY: true, stderrTTY: true, ci: "false", interactive: true },
])(
  "detects interactive input: %j",
  ({ stdinTTY, stderrTTY, ci, interactive }) => {
    expect(interactiveMode({ stdinTTY, stderrTTY, ci })).toBe(interactive);
  },
);
