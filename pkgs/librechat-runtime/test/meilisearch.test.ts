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
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import {
  MeilisearchDatabase,
  MeilisearchUpgradeError,
} from "../src/meilisearch.ts";
import type { ProcessRunner } from "../src/processes.ts";
import { ZodError } from "zod";

let state: string;

beforeEach(async () => {
  state = await mkdtemp(join(tmpdir(), "librechat-meilisearch-"));
});

afterEach(async () => {
  await rm(state, { recursive: true, force: true });
});

async function seed(version: string): Promise<void> {
  await mkdir(join(state, "meili", "indexes"), { recursive: true });
  await writeFile(join(state, "meili", "VERSION"), version);
  await writeFile(
    join(state, "meili", "indexes", "data.mdb"),
    "original index",
  );
}

it("starts a fresh database without creating a backup", async () => {
  const run = vi.fn<ProcessRunner["run"]>();
  await new MeilisearchDatabase(state).prepareUpgrade("meilisearch", { run });
  expect({ files: await readdir(state), calls: run.mock.calls }).toStrictEqual({
    files: [],
    calls: [],
  });
});

it("leaves a same-version database unchanged", async () => {
  await seed("1.56.0");
  const run = vi
    .fn<ProcessRunner["run"]>()
    .mockResolvedValue("meilisearch 1.56.0\n");
  await new MeilisearchDatabase(state).prepareUpgrade("meilisearch", { run });
  expect({ files: await readdir(state), calls: run.mock.calls }).toStrictEqual({
    files: ["meili"],
    calls: [[{ executable: "meilisearch", args: ["--version"] }]],
  });
});

it("keeps a private offline backup before upgrading and preserves it on retry", async () => {
  await seed("1.55.0");
  const processes = {
    run: vi
      .fn<ProcessRunner["run"]>()
      .mockResolvedValue("meilisearch 1.56.0\n"),
  };
  const database = new MeilisearchDatabase(state);
  await database.prepareUpgrade("meilisearch", processes);
  await writeFile(
    join(state, "meili", "indexes", "data.mdb"),
    "partially upgraded",
  );
  await database.prepareUpgrade("meilisearch", processes);
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
    new MeilisearchDatabase(state).prepareUpgrade("meilisearch", {
      run: vi
        .fn<ProcessRunner["run"]>()
        .mockResolvedValue("meilisearch 1.56.0\n"),
    }),
  ).rejects.toThrow(/ENOTDIR/u);
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
  await database.prepareUpgrade("meilisearch", {
    run: vi
      .fn<ProcessRunner["run"]>()
      .mockResolvedValue("meilisearch 1.56.0\n"),
  });
  return database;
}

function upgradeResponse(status: string, version = "1.56.0"): Response {
  return Response.json({
    results: [{ status, details: { upgradeTo: `v${version}` } }],
  });
}

it.each(["upgrade", "restart"])(
  "keeps the two newest backups after a verified %s",
  async (stage) => {
    let database = await prepareHistory();
    await writeFile(join(state, "meili", "VERSION"), "1.56.0");
    await mkdir(join(state, "meili-backups", "manual"));

    if (stage === "restart") {
      database = new MeilisearchDatabase(state);
      await database.prepareUpgrade("meilisearch", {
        run: vi
          .fn<ProcessRunner["run"]>()
          .mockResolvedValue("meilisearch 1.56.0\n"),
      });
    }

    const request = vi
      .fn<typeof fetch>()
      .mockResolvedValue(upgradeResponse("succeeded"));
    const ready = await database.upgradeReady({
      url: "http://search",
      token: "fixture",
      fetch: request,
    });

    expect({
      ready,
      files: (await readdir(join(state, "meili-backups"))).toSorted(),
      requests: request.mock.calls.map(([url, options]) => ({
        url,
        headers: options?.headers,
        signal: options?.signal instanceof AbortSignal,
      })),
    }).toStrictEqual({
      ready: true,
      files: ["1.54.0-to-1.55.0", "1.55.0-to-1.56.0", "manual"],
      requests: [
        {
          url: "http://search/tasks?types=upgradeDatabase&limit=1",
          headers: { Authorization: "Bearer fixture" },
          signal: true,
        },
      ],
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
      fetch: vi.fn<typeof fetch>().mockResolvedValue(upgradeResponse(status)),
    });
    expect({
      ready,
      files: (await readdir(join(state, "meili-backups"))).toSorted(),
    }).toStrictEqual({
      ready: false,
      files: ["1.53.0-to-1.54.0", "1.54.0-to-1.55.0", "1.55.0-to-1.56.0"],
    });
  },
);

it.each(["failed", "canceled"])(
  "preserves every backup and refuses a %s upgrade",
  async (status) => {
    const database = await prepareHistory();
    await writeFile(join(state, "meili", "VERSION"), "1.56.0");
    await expect(
      database.upgradeReady({
        url: "http://search",
        token: "fixture",
        fetch: vi.fn<typeof fetch>().mockResolvedValue(upgradeResponse(status)),
      }),
    ).rejects.toThrow(MeilisearchUpgradeError);
    expect(
      (await readdir(join(state, "meili-backups"))).toSorted(),
    ).toStrictEqual([
      "1.53.0-to-1.54.0",
      "1.54.0-to-1.55.0",
      "1.55.0-to-1.56.0",
    ]);
  },
);

it.each(["unreachable", "unauthorised"])(
  "preserves every backup when upgrade verification is %s",
  async (failure) => {
    const database = await prepareHistory();
    const request = vi.fn<typeof fetch>();

    if (failure === "unreachable") {
      request.mockRejectedValue(new Error("Search engine is offline"));
    }

    if (failure === "unauthorised") {
      request.mockResolvedValue(new Response(null, { status: 401 }));
    }

    const ready = await database.upgradeReady({
      url: "http://search",
      token: "fixture",
      fetch: request,
    });
    expect({
      ready,
      files: (await readdir(join(state, "meili-backups"))).toSorted(),
    }).toStrictEqual({
      ready: false,
      files: ["1.53.0-to-1.54.0", "1.54.0-to-1.55.0", "1.55.0-to-1.56.0"],
    });
  },
);

it("does not prune backups based on another engine's successful task", async () => {
  const database = await prepareHistory();
  const ready = await database.upgradeReady({
    url: "http://search",
    token: "fixture",
    fetch: vi
      .fn<typeof fetch>()
      .mockResolvedValue(upgradeResponse("succeeded", "1.55.0")),
  });
  expect({
    ready,
    files: (await readdir(join(state, "meili-backups"))).toSorted(),
  }).toStrictEqual({
    ready: false,
    files: ["1.53.0-to-1.54.0", "1.54.0-to-1.55.0", "1.55.0-to-1.56.0"],
  });
});

it.each([
  ["../../outside", "meilisearch 1.56.0\n"],
  ["1.55.0", "unexpected output"],
])(
  "rejects invalid versions before copying the database: %s",
  async (stored, output) => {
    await seed(stored);
    await expect(
      new MeilisearchDatabase(state).prepareUpgrade("meilisearch", {
        run: vi.fn<ProcessRunner["run"]>().mockResolvedValue(output),
      }),
    ).rejects.toThrow(ZodError);
    expect(await readdir(state)).toStrictEqual(["meili"]);
  },
);
