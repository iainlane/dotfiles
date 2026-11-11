import { readCredential } from "@dotfiles/librechat-runtime/config";
import {
  AccountBindingMismatchError,
  AccountInspectionOperationError,
  AccountRegistrationRefusedError,
  BootstrapOperationError,
  ControllerUnavailableError,
  NativeApiIncompatibleError,
  OperationalError,
  PasswordPolicyUnavailableError,
  ResetRefusedError,
} from "#cli/application/errors";
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
      if (cause instanceof inspection.AccountInspectionError) {
        throw new AccountInspectionOperationError(cause);
      }
      if (cause instanceof native.BootstrapAccountMismatchError) {
        throw new AccountBindingMismatchError(cause);
      }
      if (cause instanceof native.BootstrapRegistrationError) {
        throw new AccountRegistrationRefusedError(cause);
      }
      if (cause instanceof native.BootstrapExportError) {
        throw new NativeApiIncompatibleError(cause);
      }
      throw new BootstrapOperationError(cause);
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
          throw new PasswordPolicyUnavailableError(cause);
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
          throw new ResetRefusedError(response.status);
        }
      } catch (cause) {
        if (cause instanceof OperationalError) {
          throw cause;
        }
        throw new ControllerUnavailableError(cause);
      }
    },
  };
}
