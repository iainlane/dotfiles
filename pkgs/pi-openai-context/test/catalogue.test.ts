import type { Credential } from "@earendil-works/pi-ai";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { readCatalogue, writeCatalogue } from "#openai-context/cache.ts";
import {
  ContextCatalogue,
  type AccountWindowsResult,
  type ResolveAccountToken,
} from "#openai-context/catalogue.ts";
import {
  classifyCredential,
  readChatGptCredential,
} from "#openai-context/credential.ts";
import { readContextWindows } from "#openai-context/catalogue-client.ts";

const storedToken: ResolveAccountToken = async () => "token";

const windows = new Map([["sol", 500_000]]);
const account = {
  grant: createHash("sha256").update("fixture").digest("hex"),
  refreshAfter: 1_000,
  contextWindows: windows,
};

function login(clientId = "fixture", access = "token"): Credential {
  return {
    type: "oauth",
    access,
    refresh: "fixture",
    expires: 4_102_444_800_000,
    clientId,
  };
}

async function unavailableCatalogue(): Promise<AccountWindowsResult> {
  throw new Error("This case does not allow an account catalogue read.");
}

async function refreshCatalogue(
  catalogue: ContextCatalogue,
  resolve = storedToken,
): Promise<void> {
  const { refresh } = await catalogue.prepare(resolve);
  await refresh;
}

let directory: string;
let cachePath: string;

beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), "pi-openai-context-"));
  cachePath = join(directory, "openai-context-cache.json");
});

afterEach(async () => {
  await rm(directory, { force: true, recursive: true });
});

describe("readContextWindows", () => {
  it.each([0, -1, 1.5, Number.MAX_SAFE_INTEGER + 1, "500000"])(
    "preserves valid rows and drops invalid windows %s",
    (invalid) => {
      expect(
        readContextWindows({
          models: [
            {
              slug: "sol",
              context_window: 500_000,
              max_context_window: 872_000,
            },
            { slug: "invalid", context_window: invalid },
          ],
        }),
      ).toStrictEqual(windows);
    },
  );

  it.each([null, {}, { models: [] }, { models: [{ slug: "sol" }] }])(
    "rejects a catalogue without usable windows %s",
    (value) => {
      expect(readContextWindows(value)).toBeUndefined();
    },
  );
});

describe("readCatalogue", () => {
  it("reads the matching cache and writes it with owner-only permissions", async () => {
    await writeCatalogue(cachePath, account);
    expect({
      own: await readCatalogue(cachePath, account.grant),
      other: await readCatalogue(cachePath, "another-grant"),
      permissions: (await stat(cachePath)).mode & 0o777,
    }).toStrictEqual({ own: account, other: undefined, permissions: 0o600 });
  });

  it("treats corrupt cache files as missing", async () => {
    await writeFile(cachePath, '{"contextWindows":');
    expect(await readCatalogue(cachePath, account.grant)).toBeUndefined();
  });
});

describe("ContextCatalogue", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(50_000);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("keeps the matching window during an unreadable credential update", async () => {
    await writeCatalogue(cachePath, account);
    const authPath = join(directory, "auth.json");
    await writeFile(authPath, JSON.stringify({ openai: login() }));
    const catalogue = new ContextCatalogue({
      path: cachePath,
      offline: true,
      readCredential: () => readChatGptCredential(authPath),
      readWindows: unavailableCatalogue,
    });
    await refreshCatalogue(catalogue);
    await writeFile(authPath, '{"openai":');
    await refreshCatalogue(catalogue);
    const duringUpdate = catalogue.window("sol");
    await writeFile(authPath, "{}");
    await refreshCatalogue(catalogue);
    expect({
      duringUpdate,
      afterLogout: catalogue.window("sol"),
    }).toStrictEqual({
      duringUpdate: 500_000,
      afterLogout: undefined,
    });
  });

  it("uses a stale window immediately while a deduplicated refresh runs", async () => {
    await writeCatalogue(cachePath, account);
    const reply = new EventTarget();
    const released = once(reply, "reply");
    const catalogue = new ContextCatalogue({
      path: cachePath,
      readCredential: () => classifyCredential(login()),
      readWindows: async () => {
        await released;
        return { windows: new Map([["sol", 620_000]]) };
      },
      offline: false,
    });
    const first = await catalogue.prepare(storedToken);
    const concurrent = await catalogue.prepare(storedToken);
    expect({ cold: first.cold, cached: catalogue.window("sol") }).toStrictEqual(
      {
        cold: false,
        cached: 500_000,
      },
    );
    expect(concurrent.refresh).toBe(first.refresh);
    reply.dispatchEvent(new Event("reply"));
    await first.refresh;
    expect(catalogue.window("sol")).toBe(620_000);
  });

  it("discards a cancelled refresh after the account changes", async () => {
    let credential = login();
    const reply = new EventTarget();
    const released = once(reply, "reply");
    const catalogue = new ContextCatalogue({
      path: cachePath,
      readCredential: () => classifyCredential(credential),
      readWindows: async (token) => {
        if (token === "token") {
          await released;
          return { windows: new Map([["sol", 500_000]]) };
        }
        return { windows: new Map([["sol", 620_000]]) };
      },
      offline: false,
    });
    const old = await catalogue.prepare(storedToken);
    credential = login("another-client", "other-token");
    await refreshCatalogue(catalogue, async () => "other-token");
    reply.dispatchEvent(new Event("reply"));
    await old.refresh;
    expect(catalogue.window("sol")).toBe(620_000);
  });

  it("fetches again after the five-minute refresh interval", async () => {
    let advertisedWindow = 510_000;
    const catalogue = new ContextCatalogue({
      path: cachePath,
      readCredential: () => classifyCredential(login()),
      readWindows: async () => ({
        windows: new Map([["sol", advertisedWindow]]),
      }),
      offline: false,
    });

    await refreshCatalogue(catalogue);
    advertisedWindow = 620_000;
    vi.setSystemTime(349_999);
    await refreshCatalogue(catalogue);
    const beforeExpiry = catalogue.window("sol");
    vi.setSystemTime(350_000);
    await refreshCatalogue(catalogue);

    expect({
      beforeExpiry,
      afterExpiry: catalogue.window("sol"),
    }).toStrictEqual({
      beforeExpiry: 510_000,
      afterExpiry: 620_000,
    });
  });

  it("refreshes a saved window with an implausible future deadline", async () => {
    await writeCatalogue(cachePath, { ...account, refreshAfter: 350_001 });
    const catalogue = new ContextCatalogue({
      path: cachePath,
      readCredential: () => classifyCredential(login()),
      readWindows: async () => ({ windows: new Map([["sol", 620_000]]) }),
      offline: false,
    });

    await refreshCatalogue(catalogue);
    expect(catalogue.window("sol")).toBe(620_000);
  });

  it("uses a matching cache offline without a request and drops it on account change", async () => {
    await writeCatalogue(cachePath, account);
    let credential = login();
    const catalogue = new ContextCatalogue({
      path: cachePath,
      offline: true,
      readCredential: () => classifyCredential(credential),
      readWindows: unavailableCatalogue,
    });

    await refreshCatalogue(catalogue);
    const cached = catalogue.window("sol");
    credential = login("fixture", "rotated");
    await refreshCatalogue(catalogue);
    const rotated = catalogue.window("sol");
    credential = login("another-client");
    await refreshCatalogue(catalogue);

    expect({
      cached,
      rotated,
      other: catalogue.window("sol"),
    }).toStrictEqual({
      cached: 500_000,
      rotated: 500_000,
      other: undefined,
    });
  });

  it("keeps a stale cache after a failed read and retries after backoff", async () => {
    await writeCatalogue(cachePath, account);
    let result: AccountWindowsResult = {
      error: "Could not read the account catalogue.",
    };
    const catalogue = new ContextCatalogue({
      path: cachePath,
      readCredential: () => classifyCredential(login()),
      readWindows: async () => result,
      offline: false,
    });
    await refreshCatalogue(catalogue);
    const cached = catalogue.window("sol");
    const error = catalogue.status;
    result = { windows: new Map([["sol", 510_000]]) };
    vi.setSystemTime(79_999);
    await refreshCatalogue(catalogue);
    const beforeRetry = catalogue.window("sol");
    vi.setSystemTime(80_000);
    await refreshCatalogue(catalogue);

    expect({
      cached,
      error,
      beforeRetry,
      refreshed: catalogue.window("sol"),
    }).toStrictEqual({
      cached: 500_000,
      error:
        "Using the saved account catalogue. Could not read the account catalogue.",
      beforeRetry: 500_000,
      refreshed: 510_000,
    });
  });

  it("uses the old window when the stored access token is expired", async () => {
    await writeCatalogue(cachePath, account);
    const catalogue = new ContextCatalogue({
      path: cachePath,
      readCredential: () => classifyCredential({ ...login(), expires: 1 }),
      readWindows: unavailableCatalogue,
      offline: false,
    });
    await refreshCatalogue(catalogue, async (): Promise<undefined> => {});
    expect({
      window: catalogue.window("sol"),
      status: catalogue.status,
    }).toStrictEqual({
      window: 500_000,
      status:
        "Using the saved account catalogue. Pi could not resolve an access token for the stored ChatGPT registration.",
    });
  });

  it("keeps a successful response in memory when the cache path is unwritable", async () => {
    const catalogue = new ContextCatalogue({
      path: join(directory, "missing", "cache.json"),
      readCredential: () => classifyCredential(login()),
      readWindows: async () => ({ windows: new Map([["sol", 510_000]]) }),
      offline: false,
    });
    await refreshCatalogue(catalogue);
    expect(catalogue.window("sol")).toBe(510_000);
  });
});
