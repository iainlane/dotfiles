import { readFile } from "node:fs/promises";

/**
 * Returns the reason for the latest session start recorded in `path`. The
 * session and planning fixtures write the reason to it on each
 * `session_start`.
 */
export async function latestSessionStart(path: string): Promise<string> {
  return readFile(path, "utf8");
}
