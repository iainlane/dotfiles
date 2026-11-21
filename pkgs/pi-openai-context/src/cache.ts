import { randomUUID } from "node:crypto";
import { readFile, rename, rm, writeFile } from "node:fs/promises";
import { Check } from "typebox/value";
import { cacheSchema } from "./schemas.ts";

export interface AccountCatalogue {
  grant: string;
  contextWindows: ReadonlyMap<string, number>;
  refreshAfter: number;
}

export async function readCatalogue(
  path: string,
  grant: string,
): Promise<AccountCatalogue | undefined> {
  try {
    const data: unknown = JSON.parse(await readFile(path, "utf8"));
    if (!Check(cacheSchema, data) || data.grant !== grant) {
      return undefined;
    }

    const contextWindows = new Map(Object.entries(data.contextWindows));
    return { grant, contextWindows, refreshAfter: data.refreshAfter };
  } catch {
    return undefined;
  }
}

export async function writeCatalogue(
  path: string,
  catalogue: AccountCatalogue,
): Promise<void> {
  const temporary = `${path}.${randomUUID()}`;
  const data = {
    ...catalogue,
    contextWindows: Object.fromEntries(catalogue.contextWindows),
  };
  try {
    try {
      await writeFile(temporary, JSON.stringify(data), {
        mode: 0o600,
        flag: "wx",
      });
      await rename(temporary, path);
    } finally {
      await rm(temporary, { force: true });
    }
  } catch {
    // Catalogue refresh also runs in profiles without a writable cache.
  }
}
