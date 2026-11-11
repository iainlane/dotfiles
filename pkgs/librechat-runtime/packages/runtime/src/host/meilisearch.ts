import {
  cp,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rename,
  rm,
  stat,
  utimes,
} from "node:fs/promises";
import type { Dirent } from "node:fs";
import { join } from "node:path";
import { z } from "zod";
import type { ProcessRunner } from "#runtime/platform/processes";

const versionSchema = z.string().regex(/^\d+\.\d+\.\d+$/u);
const backupPattern = /^\d+\.\d+\.\d+-to-\d+\.\d+\.\d+$/u;
const tasksSchema = z.object({
  results: z.array(
    z.object({
      status: z.enum([
        "enqueued",
        "processing",
        "succeeded",
        "failed",
        "canceled",
      ]),
      details: z.object({ upgradeTo: z.string() }),
    }),
  ),
});

interface MeilisearchProbe {
  url: string;
  token: string;
  fetch?: typeof globalThis.fetch;
}

export class MeilisearchUpgradeError extends Error {
  constructor(status: "failed" | "canceled") {
    super(
      `Meilisearch database upgrade ${status}; check the service log and restore the pre-upgrade backup before retrying`,
    );
    this.name = "MeilisearchUpgradeError";
  }
}

export class MeilisearchBackupVersionError extends Error {
  readonly backup: string;

  constructor(backup: string) {
    super(`Meilisearch backup has an unexpected version: ${backup}`);
    this.name = "MeilisearchBackupVersionError";
    this.backup = backup;
  }
}

interface MeilisearchRuntime {
  now(): number;
  report(text: string): void;
}

const nativeRuntime: MeilisearchRuntime = {
  now: Date.now,
  report: (text) => {
    process.stderr.write(text);
  },
};

export class MeilisearchDatabase {
  private readonly state: string;
  private readonly runtime: MeilisearchRuntime;
  private versions: { source: string; target: string } | undefined;

  constructor(state: string, runtime: MeilisearchRuntime = nativeRuntime) {
    this.state = state;
    this.runtime = runtime;
  }

  async prepareUpgrade(
    executable: string,
    processes: Pick<ProcessRunner, "run">,
  ): Promise<void> {
    const database = join(this.state, "meili");
    let stored: string;

    try {
      stored = await readFile(join(database, "VERSION"), "utf8");
    } catch (error) {
      if (
        error instanceof Error &&
        "code" in error &&
        error.code === "ENOENT"
      ) {
        return;
      }

      throw error;
    }

    const source = versionSchema.parse(stored.trim());
    const output = await processes.run({ executable, args: ["--version"] });
    const target = versionSchema.parse(
      output.trim().replace(/^meilisearch /u, ""),
    );

    this.versions = { source, target };

    if (source === target) {
      return;
    }

    const backups = join(this.state, "meili-backups");
    const backup = join(backups, `${source}-to-${target}`);

    try {
      const saved = await readFile(join(backup, "VERSION"), "utf8");
      versionSchema.parse(saved.trim());

      if (saved.trim() !== source) {
        throw new MeilisearchBackupVersionError(backup);
      }

      return;
    } catch (error) {
      if (
        !(error instanceof Error && "code" in error && error.code === "ENOENT")
      ) {
        throw error;
      }
    }

    await mkdir(backups, { recursive: true, mode: 0o700 });
    const temporary = await mkdtemp(join(backups, ".pending-"));

    try {
      const copy = join(temporary, "database");
      await cp(database, copy, { recursive: true, preserveTimestamps: true });
      const created = new Date(this.runtime.now());
      await utimes(copy, created, created);
      await rename(copy, backup);
    } finally {
      await rm(temporary, { recursive: true, force: true });
    }

    this.runtime.report(
      `Meilisearch ${source} backup saved to ${backup} before upgrading to ${target}.\n`,
    );
  }

  async upgradeReady(options: MeilisearchProbe): Promise<boolean> {
    if (this.versions === undefined) {
      return true;
    }

    let response: Response;

    try {
      response = await (options.fetch ?? globalThis.fetch)(
        `${options.url}/tasks?types=upgradeDatabase&limit=1`,
        {
          headers: { Authorization: `Bearer ${options.token}` },
          signal: AbortSignal.timeout(1000),
        },
      );
    } catch {
      return false;
    }

    if (!response.ok) {
      await response.body?.cancel();
      return false;
    }

    const tasks = tasksSchema.parse(await response.json());
    const task = tasks.results.at(0);

    if (task?.details.upgradeTo !== `v${this.versions.target}`) {
      return this.versions.source === this.versions.target;
    }

    if (task.status === "failed" || task.status === "canceled") {
      throw new MeilisearchUpgradeError(task.status);
    }

    if (task.status !== "succeeded") {
      return false;
    }

    const stored = await readFile(join(this.state, "meili", "VERSION"), "utf8");

    if (versionSchema.parse(stored.trim()) !== this.versions.target) {
      return false;
    }

    await this.pruneBackups();
    return true;
  }

  private async pruneBackups(): Promise<void> {
    const directory = join(this.state, "meili-backups");
    let entries: Dirent[];

    try {
      entries = await readdir(directory, { withFileTypes: true });
    } catch (error) {
      if (
        error instanceof Error &&
        "code" in error &&
        error.code === "ENOENT"
      ) {
        return;
      }

      throw error;
    }

    const backups = await Promise.all(
      entries
        .filter(
          (entry) => entry.isDirectory() && backupPattern.test(entry.name),
        )
        .map(async (entry) => {
          const path = join(directory, entry.name);
          const { mtimeMs } = await stat(path);
          return { path, created: mtimeMs };
        }),
    );

    const expired = backups
      .toSorted(
        (left, right) =>
          right.created - left.created || right.path.localeCompare(left.path),
      )
      .slice(2);

    await Promise.all(
      expired.map((backup) =>
        rm(backup.path, { recursive: true, force: true }),
      ),
    );
  }
}
