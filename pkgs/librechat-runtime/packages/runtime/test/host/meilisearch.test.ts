import { once } from "node:events";
import {
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  stat,
  utimes,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, it } from "vitest";
import {
  MeilisearchBackupError,
  MeilisearchDatabase,
  MeilisearchUpgradeError,
  MeilisearchVersionError,
} from "#runtime/host/meilisearch";
import type { Command, ProcessRunner } from "#runtime/platform/processes";

class UnexpectedCommandError extends Error {
  constructor(command: Command) {
    super(
      `Unexpected command: ${[command.executable, ...command.args].join(" ")}`,
    );
    this.name = "UnexpectedCommandError";
  }
}

function meilisearch(versionOutput: string): Pick<ProcessRunner, "run"> {
  return {
    run: async (command) => {
      if (
        command.executable !== "meilisearch" ||
        command.args.join(" ") !== "--version"
      ) {
        throw new UnexpectedCommandError(command);
      }
      return versionOutput;
    },
  };
}

const engine = meilisearch("meilisearch 1.56.0\n");

const noExecutables: Pick<ProcessRunner, "run"> = {
  run: async (command) => {
    throw new UnexpectedCommandError(command);
  },
};

function tasksEndpoint(status: string, version = "1.56.0"): typeof fetch {
  return async (input, init) => {
    const request = new Request(input, init);
    if (request.url !== "http://search/tasks?types=upgradeDatabase&limit=1") {
      return new Response(null, { status: 404 });
    }
    if (request.headers.get("Authorization") !== "Bearer fixture") {
      return new Response(null, { status: 401 });
    }
    return Response.json({
      results: [{ status, details: { upgradeTo: `v${version}` } }],
    });
  };
}

class SearchEngineOfflineError extends Error {
  constructor() {
    super("Search engine is offline");
    this.name = "SearchEngineOfflineError";
  }
}

const offline: typeof fetch = async () => {
  throw new SearchEngineOfflineError();
};

const unanswered: typeof fetch = async (_input, init) => {
  await once(init?.signal ?? new AbortController().signal, "abort");
  throw new SearchEngineOfflineError();
};

let state: string;

beforeEach(async () => {
  state = await mkdtemp(join(tmpdir(), "librechat-meilisearch-"));
});

afterEach(async () => {
  await rm(state, { recursive: true, force: true });
});

async function rejection(operation: Promise<unknown>): Promise<unknown> {
  try {
    await operation;
  } catch (error) {
    return error;
  }

  return undefined;
}

async function seed(version: string): Promise<void> {
  await mkdir(join(state, "meili", "indexes"), { recursive: true });
  await writeFile(join(state, "meili", "VERSION"), version);
  await writeFile(
    join(state, "meili", "indexes", "data.mdb"),
    "original index",
  );
}

it("starts a fresh database without creating a backup", async () => {
  await new MeilisearchDatabase(state).prepareUpgrade(
    "meilisearch",
    noExecutables,
  );
  expect(await readdir(state)).toStrictEqual([]);
});

it("leaves a same-version database unchanged", async () => {
  await seed("1.56.0");
  await new MeilisearchDatabase(state).prepareUpgrade("meilisearch", engine);
  expect(await readdir(state)).toStrictEqual(["meili"]);
});

it("keeps a private offline backup before upgrading and preserves it on retry", async () => {
  await seed("1.55.0");
  const database = new MeilisearchDatabase(state);
  await database.prepareUpgrade("meilisearch", engine);
  await writeFile(
    join(state, "meili", "indexes", "data.mdb"),
    "partially upgraded",
  );
  await database.prepareUpgrade("meilisearch", engine);
  const backups = join(state, "meili-backups");
  const backup = join(backups, "1.55.0-to-1.56.0");
  expect({
    backups: await readdir(backups),
    mode: (await stat(backups)).mode & 0o777,
    version: await readFile(join(backup, "VERSION"), "utf8"),
    index: await readFile(join(backup, "indexes", "data.mdb"), "utf8"),
    current: await readFile(
      join(state, "meili", "indexes", "data.mdb"),
      "utf8",
    ),
  }).toStrictEqual({
    backups: ["1.55.0-to-1.56.0"],
    mode: 0o700,
    version: "1.55.0",
    index: "original index",
    current: "partially upgraded",
  });
});

it("rejects an upgrade when the backup cannot be created", async () => {
  await seed("1.55.0");
  await writeFile(join(state, "meili-backups"), "not a directory");
  await expect(
    new MeilisearchDatabase(state).prepareUpgrade("meilisearch", engine),
  ).rejects.toStrictEqual(
    new MeilisearchBackupError(
      join(state, "meili-backups", "1.55.0-to-1.56.0"),
      expect.objectContaining({ code: "ENOTDIR" }),
    ),
  );
  expect(
    await readFile(join(state, "meili", "indexes", "data.mdb"), "utf8"),
  ).toBe("original index");
});

async function prepareHistory(): Promise<MeilisearchDatabase> {
  await seed("1.55.0");
  const backups = join(state, "meili-backups");

  await Promise.all(
    [
      { source: "1.53.0", target: "1.54.0" },
      { source: "1.54.0", target: "1.55.0" },
    ].map(async ({ source, target }, index) => {
      const backup = join(backups, `${source}-to-${target}`);
      await mkdir(backup, { recursive: true });
      await writeFile(join(backup, "VERSION"), source);
      await utimes(backup, index + 1, index + 1);
    }),
  );

  await utimes(join(state, "meili"), 0, 0);
  const database = new MeilisearchDatabase(state);
  await database.prepareUpgrade("meilisearch", engine);
  return database;
}

const allBackups = ["1.53.0-to-1.54.0", "1.54.0-to-1.55.0", "1.55.0-to-1.56.0"];

it.each(["upgrade", "restart"])(
  "keeps the two newest backups after a verified %s",
  async (stage) => {
    let database = await prepareHistory();
    await writeFile(join(state, "meili", "VERSION"), "1.56.0");
    await mkdir(join(state, "meili-backups", "manual"));

    if (stage === "restart") {
      database = new MeilisearchDatabase(state);
      await database.prepareUpgrade("meilisearch", engine);
    }

    const ready = await database.upgradeReady({
      url: "http://search",
      token: "fixture",
      fetch: tasksEndpoint("succeeded"),
    });

    expect({
      ready,
      files: (await readdir(join(state, "meili-backups"))).toSorted(),
    }).toStrictEqual({
      ready: true,
      files: ["1.54.0-to-1.55.0", "1.55.0-to-1.56.0", "manual"],
    });
  },
);

it.each(["enqueued", "processing", "succeeded"])(
  "preserves every backup while the upgrade is unverified: %s",
  async (status) => {
    const database = await prepareHistory();

    if (status !== "succeeded") {
      await writeFile(join(state, "meili", "VERSION"), "1.56.0");
    }

    const ready = await database.upgradeReady({
      url: "http://search",
      token: "fixture",
      fetch: tasksEndpoint(status),
    });
    expect({
      ready,
      files: (await readdir(join(state, "meili-backups"))).toSorted(),
    }).toStrictEqual({ ready: false, files: allBackups });
  },
);

it.each(["failed", "canceled"] as const)(
  "preserves every backup and refuses a %s upgrade",
  async (status) => {
    const database = await prepareHistory();
    await writeFile(join(state, "meili", "VERSION"), "1.56.0");
    await expect(
      database.upgradeReady({
        url: "http://search",
        token: "fixture",
        fetch: tasksEndpoint(status),
      }),
    ).rejects.toStrictEqual(new MeilisearchUpgradeError(status));
    expect(
      (await readdir(join(state, "meili-backups"))).toSorted(),
    ).toStrictEqual(allBackups);
  },
);

it.each([
  { failure: "unreachable", token: "fixture", fetch: offline },
  {
    failure: "unauthorised",
    token: "another-token",
    fetch: tasksEndpoint("succeeded"),
  },
  { failure: "unanswered", token: "fixture", fetch: unanswered },
])(
  "preserves every backup when upgrade verification is $failure",
  async ({ token, fetch }) => {
    const database = await prepareHistory();
    await writeFile(join(state, "meili", "VERSION"), "1.56.0");

    const ready = await database.upgradeReady({
      url: "http://search",
      token,
      fetch,
    });
    expect({
      ready,
      files: (await readdir(join(state, "meili-backups"))).toSorted(),
    }).toStrictEqual({ ready: false, files: allBackups });
  },
);

it("does not prune backups based on another engine's successful task", async () => {
  const database = await prepareHistory();
  const ready = await database.upgradeReady({
    url: "http://search",
    token: "fixture",
    fetch: tasksEndpoint("succeeded", "1.55.0"),
  });
  expect({
    ready,
    files: (await readdir(join(state, "meili-backups"))).toSorted(),
  }).toStrictEqual({ ready: false, files: allBackups });
});

it.each([
  {
    stored: "../../outside",
    output: "meilisearch 1.56.0\n",
    error: new MeilisearchVersionError("database", "../../outside"),
  },
  {
    stored: "1.55.0",
    output: "unexpected output",
    error: new MeilisearchVersionError("executable", "unexpected output"),
  },
])(
  "rejects invalid versions before copying the database: $stored",
  async ({ stored, output, error }) => {
    await seed(stored);
    const failure = await rejection(
      new MeilisearchDatabase(state).prepareUpgrade(
        "meilisearch",
        meilisearch(output),
      ),
    );
    expect({ failure, entries: await readdir(state) }).toStrictEqual({
      failure: error,
      entries: ["meili"],
    });
  },
);

it("records backup creation through the injected clock and reporter", async () => {
  await seed("1.55.0");
  const messages: string[] = [];
  const now = 1700000000000;
  const database = new MeilisearchDatabase(state, {
    now: () => now,
    report: (text) => {
      messages.push(text);
    },
  });
  await database.prepareUpgrade("meilisearch", engine);
  const backup = join(state, "meili-backups/1.55.0-to-1.56.0");
  expect({ created: (await stat(backup)).mtimeMs, messages }).toStrictEqual({
    created: now,
    messages: [
      `Meilisearch 1.55.0 backup saved to ${backup} before upgrading to 1.56.0.\n`,
    ],
  });
});
