import { SessionStorageIdentityError } from "./errors.ts";
import { mkdir, readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import { writePrivateJson } from "./config.ts";
import type { Session, SessionStore } from "./sessions.ts";

export class JsonSessionStore implements SessionStore {
  private readonly directory: string;

  constructor(directory: string) {
    this.directory = directory;
  }

  private file(runtimeId: string): string {
    if (!/^rt_[a-f0-9]{40}$/u.test(runtimeId)) {
      throw new SessionStorageIdentityError();
    }

    return join(this.directory, runtimeId, "session.json");
  }

  async load(runtimeId: string): Promise<unknown> {
    try {
      const value: unknown = JSON.parse(
        await readFile(this.file(runtimeId), "utf8"),
      );

      return value;
    } catch (error) {
      if (
        error instanceof Error &&
        "code" in error &&
        error.code === "ENOENT"
      ) {
        return undefined;
      }

      throw error;
    }
  }

  async save(session: Session): Promise<void> {
    await writePrivateJson(this.file(session.runtimeId), session);
  }

  async list(): Promise<string[]> {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });

    return await readdir(this.directory);
  }
}
