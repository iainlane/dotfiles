import { chmod, cp, mkdir, readdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

class CodeBridgeSourceRequiredError extends Error {
  constructor() {
    super(
      "LIBRECHAT_CODE_BRIDGE is required. Enter nix develop .#librechat-runtime before preparing the workspace.",
    );
    this.name = "CodeBridgeSourceRequiredError";
  }
}

const source = process.env.LIBRECHAT_CODE_BRIDGE;

if (source === undefined || source === "") {
  throw new CodeBridgeSourceRequiredError();
}

const destination = new URL(
  "../packages/codeapi-bridge/dist/",
  import.meta.url,
);

await rm(destination, { recursive: true, force: true });
await mkdir(destination, { recursive: true });
await cp(source, destination, { recursive: true });

async function writableDirectories(directory: string): Promise<void> {
  await chmod(directory, 0o755);
  const entries = await readdir(directory, { withFileTypes: true });
  await Promise.all(
    entries
      .filter((entry) => entry.isDirectory())
      .map((entry) => writableDirectories(join(directory, entry.name))),
  );
}

await writableDirectories(fileURLToPath(destination));
