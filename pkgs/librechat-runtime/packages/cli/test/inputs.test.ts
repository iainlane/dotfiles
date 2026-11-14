import { expect, it } from "vitest";
import {
  BootstrapOptionsRequiredError,
  CancelledError,
  PasswordFileRequiredError,
  PasswordTooShortError,
  ResetOptionsRequiredError,
} from "#cli/application/errors";
import {
  resolveBootstrapInputs,
  resolveWorkspaceInput,
  interactiveMode,
} from "#cli/application/inputs";
import type { BootstrapOptions } from "#cli/definitions/commands";
import {
  DeploymentUnreachableError,
  FakeAccounts,
  FakeFiles,
  FakeTerminal,
} from "./fakes.ts";

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
  const prompts = new FakeTerminal({
    answers: {
      "Email address": ["you@example.com"],
      "Display name": ["New Name"],
    },
  });

  const result = await resolveBootstrapInputs(
    options({ passwordFile: "/unreadable" }),
    {
      accounts: new FakeAccounts({
        accounts: { "you@example.com": { name: "Existing Name" } },
        bound: "you@example.com",
      }),
      files: new FakeFiles(),
      prompts,
    },
  );

  expect({ result, screen: prompts.screen }).toStrictEqual({
    result: {
      input: {
        email: "you@example.com",
        name: "New Name",
        password: undefined,
      },
      existing: true,
    },
    screen: [
      "? Email address [you@example.com]",
      "? Display name [Existing Name]",
    ],
  });
});

it("still requests and verifies a new password with --yes", async () => {
  const accounts = new FakeAccounts();
  const prompts = new FakeTerminal({
    answers: {
      Password: ["new password"],
      "Repeat password": ["wrong", "new password"],
    },
  });

  const result = await resolveBootstrapInputs(
    options({ email: "you@example.com", name: "Your Name", yes: true }),
    { accounts, files: new FakeFiles(), prompts },
  );

  expect({
    result,
    screen: prompts.screen,
    accounts: [...accounts.accounts],
  }).toStrictEqual({
    result: {
      input: {
        email: "you@example.com",
        name: "Your Name",
        password: "new password",
      },
      existing: false,
    },
    screen: [
      "? Password (hidden)",
      "? Repeat password (hidden)",
      "! The passwords did not match.",
    ],
    accounts: [],
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
    const result = await resolveBootstrapInputs(
      options({
        email: "you@example.com",
        name: "Your Name",
        passwordFile: "/password",
      }),
      {
        accounts: new FakeAccounts(),
        files: new FakeFiles({ "/password": text }),
        prompts: new FakeTerminal({ interactive: false }),
      },
    );
    expect(result).toStrictEqual({
      input: { email: "you@example.com", name: "Your Name", password },
      existing: false,
    });
  },
);

it("reports all missing non-interactive bootstrap inputs before account access", async () => {
  await expect(
    resolveBootstrapInputs(options({ yes: true }), {
      accounts: new FakeAccounts({ failure: new DeploymentUnreachableError() }),
      files: new FakeFiles(),
      prompts: new FakeTerminal({ interactive: false }),
    }),
  ).rejects.toStrictEqual(
    new BootstrapOptionsRequiredError(["--email", "--name"]),
  );
});

it.each([true, false])(
  "requires a non-interactive password file for a new account with --yes=%s",
  async (yes) => {
    await expect(
      resolveBootstrapInputs(
        options({ email: "you@example.com", name: "Your Name", yes }),
        {
          accounts: new FakeAccounts(),
          files: new FakeFiles(),
          prompts: new FakeTerminal({ interactive: false }),
        },
      ),
    ).rejects.toStrictEqual(new PasswordFileRequiredError());
  },
);

it("does not require a password file for a non-interactive existing account", async () => {
  expect(
    await resolveBootstrapInputs(
      options({ email: "you@example.com", name: "New Name" }),
      {
        accounts: new FakeAccounts({
          accounts: { "you@example.com": { name: "Existing Name" } },
        }),
        files: new FakeFiles(),
        prompts: new FakeTerminal({ interactive: false }),
      },
    ),
  ).toStrictEqual({
    input: { email: "you@example.com", name: "New Name", password: undefined },
    existing: true,
  });
});

it("does not expose password contents when validation fails", async () => {
  await expect(
    resolveBootstrapInputs(
      options({
        email: "you@example.com",
        name: "Your Name",
        passwordFile: "/password",
      }),
      {
        accounts: new FakeAccounts(),
        files: new FakeFiles({ "/password": "secret" }),
        prompts: new FakeTerminal({ interactive: false }),
      },
    ),
  ).rejects.toStrictEqual(new PasswordTooShortError(8));
});

it("cancels bootstrap before provisioning", async () => {
  const accounts = new FakeAccounts();
  await expect(
    resolveBootstrapInputs(options(), {
      accounts,
      files: new FakeFiles(),
      prompts: new FakeTerminal(),
    }),
  ).rejects.toStrictEqual(new CancelledError());
  expect([...accounts.accounts]).toStrictEqual([]);
});

const conversation = "00000000-0000-4000-8000-000000000001";

it("prompts for a workspace ID and defaults to preserving the workspace", async () => {
  const prompts = new FakeTerminal({
    answers: { "Conversation UUID": [conversation] },
  });
  await expect(
    resolveWorkspaceInput({ conversation: undefined, yes: false }, prompts),
  ).rejects.toStrictEqual(new CancelledError());
  expect(prompts.screen).toStrictEqual([
    "? Conversation UUID",
    "? Delete this workspace, including unpushed work? (y/N)",
  ]);
});

it("uses --yes only for workspace confirmation", async () => {
  const prompts = new FakeTerminal({
    answers: { "Conversation UUID": [conversation] },
  });
  expect({
    conversation: await resolveWorkspaceInput(
      { conversation: undefined, yes: true },
      prompts,
    ),
    screen: prompts.screen,
  }).toStrictEqual({ conversation, screen: ["? Conversation UUID"] });
});

it.each([
  {
    conversation: undefined,
    yes: false,
    missing: ["--conversation", "--yes"] as const,
  },
  { conversation, yes: false, missing: ["--yes"] as const },
  { conversation: undefined, yes: true, missing: ["--conversation"] as const },
])(
  "rejects unattended workspace reset without $missing",
  async ({ conversation: suppliedConversation, yes, missing }) => {
    await expect(
      resolveWorkspaceInput(
        { conversation: suppliedConversation, yes },
        new FakeTerminal({ interactive: false }),
      ),
    ).rejects.toStrictEqual(new ResetOptionsRequiredError(missing));
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
