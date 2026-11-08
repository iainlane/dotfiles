import { readCredential } from "@dotfiles/librechat-runtime/config";
import { OperationalError } from "#cli/application/errors";
import type { Deployment, FileAccess } from "#cli/application/ports";
import { loadManifest } from "#cli/adapters/files";

export async function openDeployment(
  file: string,
  files: FileAccess,
  http: typeof globalThis.fetch,
): Promise<Deployment> {
  const manifest = await loadManifest(file, files);
  const inspection =
    await import("@dotfiles/librechat-runtime/account-inspection");
  const native = await import("@dotfiles/librechat-runtime/native-bootstrap");

  async function accountOperation<T>(operation: () => Promise<T>): Promise<T> {
    try {
      return await operation();
    } catch (cause) {
      if (
        cause instanceof inspection.AccountInspectionError ||
        cause instanceof native.BootstrapAccountMismatchError ||
        cause instanceof native.BootstrapRegistrationError
      ) {
        throw new OperationalError(cause.message, { cause });
      }
      if (cause instanceof native.BootstrapExportError) {
        throw new OperationalError(
          "The installed LibreChat native API is incompatible. Rebuild the LibreChat deployment with matching packages.",
          { cause },
        );
      }
      throw new OperationalError(
        "Could not bootstrap LibreChat. Check that the LibreChat services are running and consult their logs.",
        { cause },
      );
    }
  }

  return {
    accounts: {
      binding: async () =>
        await accountOperation(
          async () => await inspection.readAccountBinding(manifest),
        ),
      inspect: async (email) =>
        await accountOperation(
          async () => await inspection.inspectAccount(manifest, email),
        ),
      passwordIssue: (password) => {
        try {
          return native.passwordIssue(
            manifest.programs.librechatRoot,
            password,
          );
        } catch (cause) {
          throw new OperationalError(
            "The installed LibreChat password policy could not be loaded. Rebuild the deployment with matching packages.",
            { cause },
          );
        }
      },
      bootstrap: async (input) =>
        await accountOperation(
          async () => await native.bootstrapAccount(manifest, input),
        ),
    },
    url: `http://127.0.0.1:${manifest.ports.librechat}`,
    resetWorkspace: async (conversation) => {
      try {
        const token = await readCredential(
          `${manifest.stateDirectory}/secrets/controller`,
          "Generated service",
        );
        const response = await http(
          `http://127.0.0.1:${manifest.ports.controller}/reset`,
          {
            method: "POST",
            headers: {
              authorization: `Bearer ${token}`,
              "content-type": "application/json",
            },
            body: JSON.stringify({ conversationId: conversation }),
            signal: AbortSignal.timeout(30_000),
          },
        );
        await response.body?.cancel();
        if (!response.ok) {
          throw new OperationalError(
            "The controller refused the workspace reset. Finish active calls and check the conversation UUID.",
          );
        }
      } catch (cause) {
        if (cause instanceof OperationalError) {
          throw cause;
        }
        throw new OperationalError(
          "Could not contact the conversation controller. Start the LibreChat services and try again.",
          { cause },
        );
      }
    },
  };
}
