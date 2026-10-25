import { readFile } from "node:fs/promises";
import { userInfo } from "node:os";
import { setTimeout as delay } from "node:timers/promises";
import { Readable } from "node:stream";
import { parseArgs } from "node:util";
import { z } from "zod";
import { hostManifestSchema } from "./manifest.ts";
import { archiveArguments } from "./archive.ts";
import { CommandExecutionError, NodeProcessRunner } from "./processes.ts";
import { waitForSecrets } from "./startup.ts";
import { readCredential } from "./config.ts";

export class RuntimeCommandError extends Error {
  constructor() {
    super(
      "Use librechat-runtime serve <manifest>, bootstrap <manifest> --email <email> --password-file <file>, reset <manifest> --conversation <UUID>, guest <specification>, archive session <query>, or hook <configuration>",
    );

    this.name = "RuntimeCommandError";
  }
}

export class WorkspaceResetError extends Error {
  constructor() {
    super(
      "The controller refused the workspace reset; finish active calls and check the conversation ID",
    );

    this.name = "WorkspaceResetError";
  }
}

export class ArchiveQueryError extends Error {
  constructor() {
    super("The read-only AgentsView archive query failed");

    this.name = "ArchiveQueryError";
  }
}

export class ConversationHookError extends Error {
  constructor() {
    super(
      "The conversation controller could not prepare the workspace reminder",
    );

    this.name = "ConversationHookError";
  }
}

async function jsonFile(file: string): Promise<unknown> {
  return JSON.parse(await readFile(file, "utf8"));
}

function logError(error: unknown): void {
  if (error instanceof Error) {
    process.stderr.write(`${error.name}: ${error.message}\n`);

    return;
  }

  process.stderr.write("Unknown runtime failure\n");
}

async function main(args: string[]): Promise<void> {
  const [command, file] = args;

  if (
    (command === "serve" || command === "bootstrap" || command === "reset") &&
    file !== undefined
  ) {
    const manifest = hostManifestSchema.parse(await jsonFile(file));

    if (command === "reset") {
      const options = parseArgs({
        args: args.slice(2),
        strict: true,
        options: { conversation: { type: "string" } },
      });

      const { conversation } = z
        .object({ conversation: z.uuid() })
        .parse(options.values);

      const token = await readCredential(
        `${manifest.stateDirectory}/secrets/controller`,
        "Generated service",
      );

      const response = await fetch("http://127.0.0.1:3193/reset", {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ conversationId: conversation }),
        signal: AbortSignal.timeout(30_000),
      });

      await response.body?.cancel();

      if (!response.ok) {
        throw new WorkspaceResetError();
      }

      return;
    }

    if (command === "bootstrap") {
      const { bootstrapAccount } = await import("./native-bootstrap.ts");

      const options = parseArgs({
        args: args.slice(2),
        strict: true,
        options: {
          email: { type: "string" },
          "password-file": { type: "string" },
          name: { type: "string" },
        },
      });

      const input = z
        .object({
          email: z.email(),
          "password-file": z.string(),
          name: z.string().optional(),
        })
        .parse(options.values);

      await bootstrapAccount(manifest, {
        email: input.email,
        passwordFile: input["password-file"],
        name: input.name,
      });

      return;
    }

    const { NativeHostStack } = await import("./host-stack.ts");

    const abort = new AbortController();

    const stop = (): void => abort.abort();

    process.once("SIGTERM", stop);
    process.once("SIGINT", stop);

    const processes = new NodeProcessRunner({
      HOME: manifest.homeDirectory,
      PATH: "/usr/bin:/bin",
    });

    try {
      if (manifest.sopsProgram !== null) {
        const job = `gui/${userInfo().uid}/org.nix-community.home.sops-nix`;

        await waitForSecrets(manifest.sopsProgram, {
          status: async () => {
            try {
              return await processes.run({
                executable: "/bin/launchctl",
                args: ["print", job],
              });
            } catch (error) {
              if (error instanceof CommandExecutionError) {
                return "";
              }

              throw error;
            }
          },
          now: Date.now,
          pause: () => delay(100, undefined, { signal: abort.signal }),
        });
      }

      await new NativeHostStack(manifest, abort.signal, processes).serve();
    } catch (error) {
      if (
        !abort.signal.aborted ||
        !(error instanceof Error) ||
        error.name !== "AbortError"
      ) {
        throw error;
      }
    } finally {
      process.removeListener("SIGTERM", stop);
      process.removeListener("SIGINT", stop);
    }

    return;
  }

  if (command === "guest" && file !== undefined) {
    const { guestHttpService, guestSpecificationSchema, NodeGuestOperations } =
      await import("./guest.ts");

    const specification = guestSpecificationSchema.parse(await jsonFile(file));

    const processes = new NodeProcessRunner({
      PATH: "/run/current-system/sw/bin",
      HOME: "/root",
    });

    const operations = new NodeGuestOperations(
      specification,
      processes,
      globalThis.fetch,
    );

    const server = guestHttpService(operations, logError);

    server.on("error", (error) => {
      logError(error);

      process.exitCode = 1;
    });

    server.listen(8080, "0.0.0.0");

    return;
  }

  if (command === "archive") {
    const query = archiveArguments(args.slice(1));

    const token =
      process.env.AGENTSVIEW_BROKER_TOKEN ??
      (await readCredential(
        "/run/librechat-guest/archive-token",
        "Generated service",
      ));

    const response = await fetch("http://10.0.2.102:3194/query", {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(query),
      signal: AbortSignal.timeout(30_000),
    });

    if (!response.ok) {
      await response.body?.cancel();

      throw new ArchiveQueryError();
    }

    process.stdout.write(await response.text());

    return;
  }

  if (command === "hook" && file !== undefined) {
    const configuration = z
      .object({ tokenFile: z.string(), baseURL: z.url() })
      .parse(await jsonFile(file));

    const input: unknown = JSON.parse(
      await new Response(Readable.toWeb(process.stdin)).text(),
    );

    const payload = z.object({ session_id: z.uuid() }).parse(input);

    const token = await readCredential(
      configuration.tokenFile,
      "Generated service",
    );

    const response = await fetch(`${configuration.baseURL}/activate`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ conversationId: payload.session_id }),
      signal: AbortSignal.timeout(180_000),
    });

    if (!response.ok) {
      await response.body?.cancel();

      throw new ConversationHookError();
    }

    const result: unknown = await response.json();

    const reminder = z.object({ additionalContext: z.string() }).parse(result);

    process.stdout.write(`${JSON.stringify(reminder)}\n`);

    return;
  }

  throw new RuntimeCommandError();
}

try {
  await main(process.argv.slice(2));
} catch (error) {
  logError(error);

  process.exitCode = 1;
}
