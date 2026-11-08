import { userInfo } from "node:os";
import { Readable } from "node:stream";
import { setTimeout as delay } from "node:timers/promises";
import { z } from "zod";
import {
  CommandExecutionError,
  NodeProcessRunner,
} from "@dotfiles/librechat-runtime/processes";
import { waitForSecrets } from "@dotfiles/librechat-runtime/startup";
import { readCredential } from "@dotfiles/librechat-runtime/config";
import { OperationalError, UsageError } from "#cli/application/errors";
import type { FileAccess, RuntimeServices } from "#cli/application/ports";
import { jsonFile, loadManifest } from "#cli/adapters/files";

interface RuntimeEffects {
  files: FileAccess;
  http: typeof globalThis.fetch;
  input: Readable;
  brokerToken: string | undefined;
  writeOutput(text: string): void;
  reportError(error: unknown): void;
}

async function operational<T>(
  message: string,
  operation: () => Promise<T>,
): Promise<T> {
  try {
    return await operation();
  } catch (cause) {
    if (cause instanceof OperationalError || cause instanceof UsageError) {
      throw cause;
    }
    throw new OperationalError(message, { cause });
  }
}

export class NativeRuntimeServices implements RuntimeServices {
  private readonly effects: RuntimeEffects;

  constructor(effects: RuntimeEffects) {
    this.effects = effects;
  }

  async serve(file: string): Promise<void> {
    await operational(
      "Could not start the LibreChat host services. Check the service logs.",
      async () => {
        const manifest = await loadManifest(file, this.effects.files);
        const { NativeHostStack } =
          await import("@dotfiles/librechat-runtime/host-stack");
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
      },
    );
  }

  async guest(file: string): Promise<void> {
    await operational(
      "Could not start the LibreChat guest service. Check its configuration and logs.",
      async () => {
        const {
          guestHttpService,
          guestSpecificationSchema,
          NodeGuestOperations,
        } = await import("@dotfiles/librechat-runtime/guest");
        const specification = guestSpecificationSchema.parse(
          await jsonFile(file, this.effects.files),
        );
        const processes = new NodeProcessRunner({
          PATH: "/run/current-system/sw/bin",
          HOME: "/root",
        });
        const onError = (cause: unknown): void =>
          this.effects.reportError(
            new OperationalError(
              "The LibreChat guest operation failed. Check the guest service logs.",
              { cause },
            ),
          );
        const operations = new NodeGuestOperations(specification, processes, {
          fetch: this.effects.http,
          onError,
        });
        const server = guestHttpService(operations, onError);
        server.on("error", (error) => {
          onError(error);
          process.exitCode = 1;
        });
        server.listen(8080, "0.0.0.0");
      },
    );
  }

  async archive(query: string[]): Promise<string> {
    return await operational(
      "The read-only AgentsView archive query failed. Check the archive service.",
      async () => {
        const token =
          this.effects.brokerToken ??
          (await readCredential(
            "/run/librechat-guest/archive-token",
            "Generated service",
          ));
        const response = await this.effects.http(
          "http://10.0.2.102:3194/query",
          {
            method: "POST",
            headers: {
              authorization: `Bearer ${token}`,
              "content-type": "application/json",
            },
            body: JSON.stringify(query),
            signal: AbortSignal.timeout(30_000),
          },
        );
        if (!response.ok) {
          await response.body?.cancel();
          throw new OperationalError(
            "The read-only AgentsView archive query failed. Check the archive service.",
          );
        }
        return await response.text();
      },
    );
  }

  async hook(file: string): Promise<void> {
    await operational(
      "The conversation controller could not prepare the workspace reminder. Check the LibreChat services.",
      async () => {
        const configuration = z
          .object({ tokenFile: z.string(), baseURL: z.url() })
          .parse(await jsonFile(file, this.effects.files));
        const text = await new Response(
          Readable.toWeb(this.effects.input),
        ).text();
        let conversation: string;
        try {
          const input: unknown = JSON.parse(text);
          conversation = z
            .object({ session_id: z.uuid() })
            .parse(input).session_id;
        } catch (cause) {
          throw new UsageError(
            "Invalid conversation hook input. Expected a session_id UUID in JSON.",
            { cause },
          );
        }
        const token = await readCredential(
          configuration.tokenFile,
          "Generated service",
        );
        const response = await this.effects.http(
          `${configuration.baseURL}/activity`,
          {
            method: "POST",
            headers: {
              authorization: `Bearer ${token}`,
              "content-type": "application/json",
            },
            body: JSON.stringify({ conversationId: conversation }),
            signal: AbortSignal.timeout(180_000),
          },
        );
        if (!response.ok) {
          await response.body?.cancel();
          throw new OperationalError(
            "The conversation controller could not prepare the workspace reminder. Check the LibreChat services.",
          );
        }
        const result: unknown = await response.json();
        const reminder = z
          .object({ additionalContext: z.string() })
          .parse(result);
        this.effects.writeOutput(`${JSON.stringify(reminder)}\n`);
      },
    );
  }
}
