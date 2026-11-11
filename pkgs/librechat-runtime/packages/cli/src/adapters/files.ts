import {
  hostManifestSchema,
  type HostManifest,
} from "@dotfiles/librechat-runtime/manifest";
import { DeploymentConfigurationError } from "#cli/application/errors";
import type { FileAccess } from "#cli/application/ports";

export async function jsonFile(
  file: string,
  files: FileAccess,
): Promise<unknown> {
  return JSON.parse(await files.readText(file));
}

export async function loadManifest(
  file: string,
  files: FileAccess,
): Promise<HostManifest> {
  try {
    return hostManifestSchema.parse(await jsonFile(file, files));
  } catch (cause) {
    throw new DeploymentConfigurationError(cause);
  }
}
