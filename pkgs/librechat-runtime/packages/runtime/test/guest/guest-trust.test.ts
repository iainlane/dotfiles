import { expect, it } from "vitest";
import {
  GuestWorkspaceIdentityError,
  GuestWorkspaceTrust,
} from "#runtime/guest/guest-trust";
import type { Command } from "#runtime/platform/processes";
import { CommandExecutionError } from "#runtime/platform/processes";

const options = {
  uid: 200000,
  gid: 200000,
  mkdir: "/tools/mkdir",
  certutil: "/tools/certutil",
};

const workspaceIdentity = { uid: 200000, gid: 200000, directory: true };

const database = "/work/.pki/nssdb";

class UnsupportedCommandError extends Error {
  constructor() {
    super("The fixture workspace does not support this command");

    this.name = "UnsupportedCommandError";
  }
}

class MissingDirectoryError extends Error {
  constructor() {
    super("certutil requires an existing database directory");

    this.name = "MissingDirectoryError";
  }
}

class DatabaseStateError extends Error {
  constructor() {
    super("certutil found an unexpected NSS database state");

    this.name = "DatabaseStateError";
  }
}

interface Owner {
  uid: number;
  gid: number;
}

interface Certificate {
  nickname: string;
  trust: string;
  file: string;
}

function flagValues(args: string[]): Map<string, string> {
  return new Map(
    args.flatMap((arg, index) => {
      const value = args[index + 1];

      return arg.startsWith("-") &&
        value !== undefined &&
        !value.startsWith("-")
        ? [[arg, value] as const]
        : [];
    }),
  );
}

class FixtureWorkspace {
  readonly directories = new Map<string, Owner & { mode: string }>();
  readonly databases = new Map<
    string,
    Owner & { certificates: Certificate[] }
  >();
  writable = true;

  constructor(existingDatabase = false) {
    if (existingDatabase) {
      this.directories.set(database, { mode: "700", uid: 200000, gid: 200000 });
      this.databases.set(database, {
        uid: 200000,
        gid: 200000,
        certificates: [],
      });
    }
  }

  async run(command: Command): Promise<string> {
    const owner = { uid: command.uid ?? 0, gid: command.gid ?? 0 };
    const [flag, ...rest] = command.args;

    if (command.executable === options.mkdir && flag === "-p") {
      const [modeFlag, mode, separator, path] = rest;

      if (modeFlag !== "-m" || mode === undefined || separator !== "--") {
        throw new UnsupportedCommandError();
      }

      if (!this.writable) {
        throw new CommandExecutionError(command, { code: "EACCES" });
      }

      if (path !== undefined && !this.directories.has(path)) {
        this.directories.set(path, { mode, ...owner });
      }

      return "";
    }

    const values = flagValues(rest);
    const directory = values.get("-d")?.replace(/^sql:/u, "");

    if (command.executable !== options.certutil || directory === undefined) {
      throw new UnsupportedCommandError();
    }

    if (!this.directories.has(directory)) {
      throw new MissingDirectoryError();
    }

    const existing = this.databases.get(directory);

    if (flag === "-N" && rest.includes("--empty-password")) {
      if (existing !== undefined) {
        throw new DatabaseStateError();
      }

      this.databases.set(directory, { ...owner, certificates: [] });

      return "";
    }

    const nickname = values.get("-n");
    const trust = values.get("-t");
    const file = values.get("-i");

    if (
      flag !== "-A" ||
      nickname === undefined ||
      trust === undefined ||
      file === undefined
    ) {
      throw new UnsupportedCommandError();
    }

    if (existing === undefined) {
      throw new DatabaseStateError();
    }

    existing.certificates.push({ nickname, trust, file });

    return "";
  }

  state() {
    return {
      directories: Object.fromEntries(this.directories),
      databases: Object.fromEntries(this.databases),
    };
  }
}

function fixture(workspace: FixtureWorkspace, identity = workspaceIdentity) {
  return new GuestWorkspaceTrust(options, {
    inspect: async () => identity,
    databaseExists: async () => workspace.databases.has(database),
    run: async (command) => await workspace.run(command),
  });
}

it.each([false, true])(
  "prepares NSS as the configured workspace user with existing database %s",
  async (existing) => {
    const workspace = new FixtureWorkspace(existing);

    const identity = await fixture(workspace).prepare();

    expect({ identity, workspace: workspace.state() }).toStrictEqual({
      identity: { uid: 200000, gid: 200000 },
      workspace: {
        directories: {
          [database]: { mode: "700", uid: 200000, gid: 200000 },
        },
        databases: {
          [database]: {
            uid: 200000,
            gid: 200000,
            certificates: [
              {
                nickname: "LibreChat egress CA",
                trust: "C,,",
                file: "/run/librechat-guest/iron-ca.crt",
              },
            ],
          },
        },
      },
    });
  },
);

it.each([
  { uid: 0, gid: 200000, directory: true },
  { uid: 200000, gid: 0, directory: true },
  { uid: 200000, gid: 200000, directory: false },
])("rejects workspace identity %j before any mutation", async (identity) => {
  const workspace = new FixtureWorkspace();

  await expect(fixture(workspace, identity).prepare()).rejects.toStrictEqual(
    new GuestWorkspaceIdentityError(),
  );

  expect(workspace.state()).toStrictEqual({ directories: {}, databases: {} });
});

it("stops trust setup when the workspace user cannot create the directory", async () => {
  const workspace = new FixtureWorkspace();
  workspace.writable = false;

  await expect(fixture(workspace).prepare()).rejects.toStrictEqual(
    new CommandExecutionError(
      {
        executable: "/tools/mkdir",
        args: ["-p", "-m", "700", "--", database],
        uid: 200000,
        gid: 200000,
      },
      { code: "EACCES" },
    ),
  );

  expect(workspace.state()).toStrictEqual({ directories: {}, databases: {} });
});
