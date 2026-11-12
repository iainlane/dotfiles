import { userInfo } from "node:os";
import type { Logger } from "@logtape/logtape";
import { errorDiagnostic } from "@dotfiles/librechat-runtime/diagnostics";
import { Readable } from "node:stream";
import { setTimeout as delay } from "node:timers/promises";
import { z } from "zod";
import {
  CommandExecutionError,
  NodeProcessRunner,
} from "@dotfiles/librechat-runtime/processes";
import { waitForSecrets } from "@dotfiles/librechat-runtime/startup";
import { readCredential } from "@dotfiles/librechat-runtime/config";
import {
  ArchiveHttpError,
  ArchiveQueryError,
  GuestOperationError,
  GuestStartupError,
  HookInputError,
  HostStartupError,
  OperationalError,
  UsageError,
  WorkspaceReminderError,
  WorkspaceReminderHttpError,
} from "#cli/application/errors";
import type { FileAccess, RuntimeServices } from "#cli/application/ports";
import { jsonFile, loadManifest } from "#cli/adapters/files";

interface RuntimeEffects {
  files: FileAccess;
  http: typeof globalThis.fetch;
  input: Readable;
  brokerToken: string | undefined;
  secrets: string[];
  writeOutput(text: string): void;
}

async function operational<T>(
  Failure: new (cause: unknown) => OperationalError,
  operation: () => Promise<T>,
): Promise<T> {
  try {
    return await operation();
  } catch (cause) {
    if (cause instanceof OperationalError || cause instanceof UsageError) {
      throw cause;
    }
    throw new Failure(cause);
  }
}

export class NativeRuntimeServices implements RuntimeServices {
  private readonly effects: RuntimeEffects;

  constructor(effects: RuntimeEffects) {
    this.effects = effects;
  }

  async serve(file: string, logger: Logger): Promise<void> {
    await operational(HostStartupError, async () => {
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
        await new NativeHostStack(manifest, abort.signal, processes, {
          logger: logger.with({ service: "host" }),
          secrets: this.effects.secrets,
        }).serve();
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
    });
  }

  async guest(file: string, logger: Logger): Promise<void> {
    const guestLogger = logger.with({ service: "guest" });
    const onError = (cause: unknown): void => {
      guestLogger.error("Guest operation failed", {
        event: "librechat-service-error",
        error: errorDiagnostic(
          new GuestOperationError(cause),
          this.effects.secrets,
        ),
      });
    };
    await operational(GuestStartupError, async () => {
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
    });
  }

  async archive(query: string[]): Promise<string> {
    return await operational(ArchiveQueryError, async () => {
      const token =
        this.effects.brokerToken ??
        (await readCredential(
          "/run/librechat-guest/archive-token",
          "Generated service",
        ));
      const response = await this.effects.http("http://10.0.2.102:3194/query", {
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
        throw new ArchiveHttpError(response.status);
      }
      return await response.text();
    });
  }

  async hook(file: string): Promise<void> {
    await operational(WorkspaceReminderError, async () => {
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
        throw new HookInputError(cause);
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
        throw new WorkspaceReminderHttpError(response.status);
      }
      const result: unknown = await response.json();
      const reminder = z
        .object({ additionalContext: z.string() })
        .parse(result);
      this.effects.writeOutput(`${JSON.stringify(reminder)}\n`);
    });
  }
}
