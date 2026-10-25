import { expect, it } from "vitest";
import {
  GuestWorkspaceIdentityError,
  GuestWorkspaceTrust,
} from "./guest-trust.ts";
import type { Command } from "./processes.ts";
import { CommandExecutionError } from "./processes.ts";

const options = {
  uid: 200000,
  gid: 200000,
  mkdir: "/tools/mkdir",
  certutil: "/tools/certutil",
};

const workspaceIdentity = { uid: 200000, gid: 200000, directory: true };

function fixture(databaseExists = false, identity = workspaceIdentity) {
  const commands: Command[] = [];

  const trust = new GuestWorkspaceTrust(options, {
    inspect: async () => identity,
    databaseExists: async () => databaseExists,
    run: async (command) => {
      commands.push(command);

      return "";
    },
  });

  return { trust, commands };
}

it.each([false, true])(
  "prepares NSS as the configured workspace user with existing database %s",
  async (existing) => {
    const { trust, commands } = fixture(existing);

    const identity = await trust.prepare();

    expect({ identity, commands }).toStrictEqual({
      identity: { uid: 200000, gid: 200000 },
      commands: [
        {
          executable: "/tools/mkdir",
          args: ["-p", "-m", "700", "--", "/tmp/sandbox/session/.pki/nssdb"],
          uid: 200000,
          gid: 200000,
        },
        ...(existing
          ? []
          : [
              {
                executable: "/tools/certutil",
                args: [
                  "-N",
                  "--empty-password",
                  "-d",
                  "sql:/tmp/sandbox/session/.pki/nssdb",
                ],
                uid: 200000,
                gid: 200000,
              },
            ]),
        {
          executable: "/tools/certutil",
          args: [
            "-A",
            "-n",
            "LibreChat egress CA",
            "-t",
            "C,,",
            "-i",
            "/run/librechat-guest/iron-ca.crt",
            "-d",
            "sql:/tmp/sandbox/session/.pki/nssdb",
          ],
          uid: 200000,
          gid: 200000,
        },
      ],
    });
  },
);

it.each([
  { uid: 0, gid: 200000, directory: true },
  { uid: 200000, gid: 0, directory: true },
  { uid: 200000, gid: 200000, directory: false },
])("rejects workspace identity %j before any mutation", async (identity) => {
  const { trust, commands } = fixture(false, identity);

  await expect(trust.prepare()).rejects.toBeInstanceOf(
    GuestWorkspaceIdentityError,
  );

  expect(commands).toStrictEqual([]);
});

it("stops trust setup when the workspace user cannot create the directory", async () => {
  const commands: Command[] = [];

  const trust = new GuestWorkspaceTrust(options, {
    inspect: async () => workspaceIdentity,
    databaseExists: async () => false,
    run: async (command) => {
      commands.push(command);

      throw new CommandExecutionError(command, { code: "EACCES" });
    },
  });

  await expect(trust.prepare()).rejects.toBeInstanceOf(CommandExecutionError);

  expect(commands).toStrictEqual([
    {
      executable: "/tools/mkdir",
      args: ["-p", "-m", "700", "--", "/tmp/sandbox/session/.pki/nssdb"],
      uid: 200000,
      gid: 200000,
    },
  ]);
});
