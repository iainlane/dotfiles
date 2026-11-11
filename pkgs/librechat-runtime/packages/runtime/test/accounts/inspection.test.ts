import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import { errorDiagnostic } from "#runtime/platform/diagnostics";
import {
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

async function fixture() {
  const stateDirectory = await mkdtemp(join(tmpdir(), "librechat-account-"));
  directories.push(stateDirectory);
  await writeFile(
    join(stateDirectory, "connection.json"),
    JSON.stringify({ mongoUri: "mongodb://127.0.0.1/test" }),
  );
  const reader = {
    findByEmail: vi.fn<AccountReader["findByEmail"]>().mockResolvedValue(null),
    close: vi.fn<AccountReader["close"]>().mockResolvedValue(undefined),
  };
  const connect = vi
    .fn<(uri: string) => Promise<AccountReader>>()
    .mockResolvedValue(reader);
  return { deployment: { stateDirectory }, reader, connect };
}

it("allows an unbound deployment without inventing an account", async () => {
  const { deployment, reader, connect } = await fixture();
  expect({
    binding: await readAccountBinding(deployment),
    summary: await inspectAccount(deployment, "you@example.com", connect),
    closed: reader.close.mock.calls,
  }).toStrictEqual({
    binding: null,
    summary: { exists: false, name: undefined },
    closed: [[]],
  });
});

it("reads the bound account and its current display name", async () => {
  const { deployment, reader, connect } = await fixture();
  const binding = {
    userId: "0123456789abcdef01234567",
    email: "you@example.com",
  };
  await writeFile(
    join(deployment.stateDirectory, "account.json"),
    JSON.stringify(binding),
  );
  reader.findByEmail.mockResolvedValue({
    _id: binding.userId,
    email: binding.email,
    name: "Your Name",
  });
  expect({
    binding: await readAccountBinding(deployment),
    summary: await inspectAccount(deployment, binding.email, connect),
    lookup: reader.findByEmail.mock.calls,
    closed: reader.close.mock.calls,
  }).toStrictEqual({
    binding,
    summary: { exists: true, name: "Your Name" },
    lookup: [[binding.email]],
    closed: [[]],
  });
});

it("rejects another email before opening the database", async () => {
  const { deployment, connect } = await fixture();
  await writeFile(
    join(deployment.stateDirectory, "account.json"),
    JSON.stringify({
      userId: "0123456789abcdef01234567",
      email: "you@example.com",
    }),
  );
  await expect(
    inspectAccount(deployment, "other@example.com", connect),
  ).rejects.toThrow(
    "This deployment is already bound to another personal account.",
  );
  expect(connect.mock.calls).toStrictEqual([]);
});

it.each([null, { _id: "abcdef0123456789abcdef01", email: "you@example.com" }])(
  "rejects a missing or different bound database identity: %j",
  async (record) => {
    const { deployment, reader, connect } = await fixture();
    await writeFile(
      join(deployment.stateDirectory, "account.json"),
      JSON.stringify({
        userId: "0123456789abcdef01234567",
        email: "you@example.com",
      }),
    );
    reader.findByEmail.mockResolvedValue(record);
    await expect(
      inspectAccount(deployment, "you@example.com", connect),
    ).rejects.toThrow(
      "The bound personal account does not match the database. Check the deployment's account state.",
    );
    expect(reader.close.mock.calls).toStrictEqual([[]]);
  },
);

it("closes account-inspection connections and does not expose database errors", async () => {
  const { deployment, reader, connect } = await fixture();
  reader.findByEmail.mockRejectedValue(
    Object.assign(new Error("mongodb://private:secret@example.com"), {
      stack: undefined,
    }),
  );
  let failure: unknown;
  try {
    await inspectAccount(deployment, "you@example.com", connect);
  } catch (error) {
    failure =
      error instanceof Error
        ? Object.assign(error, { stack: undefined })
        : error;
  }
  expect({
    closed: reader.close.mock.calls,
    diagnostic: errorDiagnostic(failure),
  }).toStrictEqual({
    closed: [[]],
    diagnostic: {
      name: "AccountInspectionError",
      message:
        "Could not read the LibreChat account database. Check that the LibreChat services are running.",
      cause: { name: "Error", message: "mongodb://example.com" },
    },
  });
});
