import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { MongoClient } from "mongodb";
import { z } from "zod";
import type { HostManifest } from "#runtime/host/manifest";

const bindingSchema = z.object({
  userId: z.string().regex(/^[a-f0-9]{24}$/u),
  email: z.email(),
});
const accountSchema = z
  .object({
    _id: z.coerce.string().regex(/^[a-f0-9]{24}$/u),
    email: z.email(),
    name: z.string().nullish(),
  })
  .transform(({ _id: userId, ...account }) => ({ ...account, userId }));
const messages = {
  state:
    "The LibreChat deployment is not initialised. Start its services and check its account state.",
  email: "This deployment is already bound to another personal account.",
  identity:
    "The bound personal account does not match the database. Check the deployment's account state.",
  database:
    "Could not read the LibreChat account database. Check that the LibreChat services are running.",
  incompatible:
    "LibreChat returned an invalid account record. Check that the installed packages are compatible.",
};

export class AccountInspectionError extends Error {
  readonly reason: keyof typeof messages;

  constructor(reason: keyof typeof messages, options?: ErrorOptions) {
    super(messages[reason], options);
    this.name = "AccountInspectionError";
    this.reason = reason;
  }
}

export interface AccountReader {
  findByEmail(email: string): Promise<unknown>;
  close(): Promise<void>;
}

type DeploymentState = Pick<HostManifest, "stateDirectory">;

export async function readAccountBinding(
  manifest: DeploymentState,
): Promise<z.infer<typeof bindingSchema> | null> {
  try {
    const raw: unknown = JSON.parse(
      await readFile(join(manifest.stateDirectory, "account.json"), "utf8"),
    );
    return bindingSchema.parse(raw);
  } catch (cause) {
    if (cause instanceof Error && "code" in cause && cause.code === "ENOENT") {
      return null;
    }
    throw new AccountInspectionError("state", { cause });
  }
}

async function connect(uri: string): Promise<AccountReader> {
  const client = new MongoClient(uri, {
    serverSelectionTimeoutMS: 5000,
    connectTimeoutMS: 5000,
  });
  try {
    await client.connect();
  } catch (cause) {
    await client.close();
    throw cause;
  }
  return {
    findByEmail: async (email) =>
      await client
        .db()
        .collection("users")
        .findOne({ email }, { projection: { _id: 1, email: 1, name: 1 } }),
    close: async () => await client.close(),
  };
}

export async function inspectAccount(
  manifest: DeploymentState,
  email: string,
  open: (uri: string) => Promise<AccountReader> = connect,
): Promise<{ exists: boolean; name: string | undefined }> {
  const binding = await readAccountBinding(manifest);
  if (binding !== null && binding.email.toLowerCase() !== email.toLowerCase()) {
    throw new AccountInspectionError("email");
  }
  let uri: string;
  try {
    const raw: unknown = JSON.parse(
      await readFile(join(manifest.stateDirectory, "connection.json"), "utf8"),
    );
    uri = z.object({ mongoUri: z.string() }).parse(raw).mongoUri;
  } catch (cause) {
    throw new AccountInspectionError("state", { cause });
  }
  try {
    const reader = await open(uri);
    try {
      const raw = await reader.findByEmail(email.toLowerCase());
      const result = accountSchema.nullable().safeParse(raw);
      if (!result.success) {
        throw new AccountInspectionError("incompatible", {
          cause: result.error,
        });
      }
      const account = result.data;
      if (
        binding !== null &&
        (account === null ||
          account.userId !== binding.userId ||
          account.email.toLowerCase() !== binding.email.toLowerCase())
      ) {
        throw new AccountInspectionError("identity");
      }
      return { exists: account !== null, name: account?.name ?? undefined };
    } finally {
      await reader.close();
    }
  } catch (cause) {
    if (cause instanceof AccountInspectionError) {
      throw cause;
    }
    throw new AccountInspectionError("database", { cause });
  }
}
