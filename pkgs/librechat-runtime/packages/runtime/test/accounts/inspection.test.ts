import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import {
  AccountInspectionError,
  inspectAccount,
  readAccountBinding,
  type AccountReader,
} from "#runtime/accounts/inspection";

const directories: string[] = [];
afterEach(async () => {
  await Promise.all(
    directories
      .splice(0)
      .map(
        async (directory) =>
          await rm(directory, { recursive: true, force: true }),
      ),
  );
});

const mongoUri = "mongodb://127.0.0.1/test";

class DatabaseUnreachableError extends Error {
  constructor(uri: string) {
    super(`Cannot connect to ${uri}`);
    this.name = "DatabaseUnreachableError";
  }
}

class AccountDatabase {
  readonly users = new Map<string, unknown>();
  readonly connections = new Set<AccountReader>();
  reachable = true;
  failure: Error | undefined;

  readonly open = async (uri: string): Promise<AccountReader> => {
    if (!this.reachable || uri !== mongoUri) {
      throw new DatabaseUnreachableError(uri);
    }
    const reader: AccountReader = {
      findByEmail: async (email) => {
        if (this.failure !== undefined) {
          throw this.failure;
        }
        return this.users.get(email) ?? null;
      },
      close: async () => {
        this.connections.delete(reader);
      },
    };
    this.connections.add(reader);
    return reader;
  };
}

async function fixture() {
  const stateDirectory = await mkdtemp(join(tmpdir(), "librechat-account-"));
  directories.push(stateDirectory);
  await writeFile(
    join(stateDirectory, "connection.json"),
    JSON.stringify({ mongoUri }),
  );
  return { deployment: { stateDirectory }, database: new AccountDatabase() };
}

const binding = {
  userId: "0123456789abcdef01234567",
  email: "you@example.com",
};

async function bind(stateDirectory: string): Promise<void> {
  await writeFile(
    join(stateDirectory, "account.json"),
    JSON.stringify(binding),
  );
}

it("allows an unbound deployment without inventing an account", async () => {
  const { deployment, database } = await fixture();
  expect({
    binding: await readAccountBinding(deployment),
    summary: await inspectAccount(deployment, "you@example.com", database.open),
    openConnections: database.connections.size,
  }).toStrictEqual({
    binding: null,
    summary: { exists: false, name: undefined },
    openConnections: 0,
  });
});

it("reads the bound account and its current display name", async () => {
  const { deployment, database } = await fixture();
  await bind(deployment.stateDirectory);
  database.users.set(binding.email, {
    _id: binding.userId,
    email: binding.email,
    name: "Your Name",
  });
  expect({
    binding: await readAccountBinding(deployment),
    summary: await inspectAccount(deployment, binding.email, database.open),
    openConnections: database.connections.size,
  }).toStrictEqual({
    binding,
    summary: { exists: true, name: "Your Name" },
    openConnections: 0,
  });
});

it("rejects another email before opening the database", async () => {
  const { deployment, database } = await fixture();
  await bind(deployment.stateDirectory);
  database.reachable = false;
  await expect(
    inspectAccount(deployment, "other@example.com", database.open),
  ).rejects.toStrictEqual(new AccountInspectionError("email"));
});

it.each([null, { _id: "abcdef0123456789abcdef01", email: "you@example.com" }])(
  "rejects a missing or different bound database identity: %j",
  async (record) => {
    const { deployment, database } = await fixture();
    await bind(deployment.stateDirectory);
    if (record !== null) {
      database.users.set(record.email, record);
    }
    await expect(
      inspectAccount(deployment, "you@example.com", database.open),
    ).rejects.toStrictEqual(new AccountInspectionError("identity"));
    expect(database.connections.size).toBe(0);
  },
);

it("closes account-inspection connections and does not expose database errors", async () => {
  const { deployment, database } = await fixture();
  const cause = new Error("mongodb://private:secret@example.com");
  database.failure = cause;
  await expect(
    inspectAccount(deployment, "you@example.com", database.open),
  ).rejects.toStrictEqual(new AccountInspectionError("database", { cause }));
  expect(database.connections.size).toBe(0);
});
