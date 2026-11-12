import { readFile } from "node:fs/promises";

/**
 * Returns the number of session starts recorded in `path`. The session and
 * planning fixtures append one line to it on each `session_start`.
 */
export async function sessionStarts(path: string): Promise<number> {
  return (await readFile(path, "utf8")).split("\n").length - 1;
}
