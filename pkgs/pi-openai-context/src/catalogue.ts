import { createHash } from "node:crypto";
import { once } from "node:events";
import {
  type AccountCatalogue,
  readCatalogue,
  writeCatalogue,
} from "./cache.ts";
import type { CredentialRead } from "./credential.ts";

const deadlineMs = 4_000;
const refreshIntervalMs = 5 * 60_000;
const retryIntervalMs = 30_000;

export type AccountWindowsResult =
  | { windows: ReadonlyMap<string, number> }
  | { error: string };

export type ReadAccountWindows = (
  token: string,
  signal: AbortSignal,
) => Promise<AccountWindowsResult>;

export type ResolveAccountToken = () => Promise<string | undefined>;

type AccountLogin = { grant: string };

function grantKey(clientId: string): string {
  return createHash("sha256").update(clientId).digest("hex");
}

async function waitForRefresh(
  work: Promise<void>,
  signal: AbortSignal,
): Promise<void> {
  const listening = new AbortController();
  try {
    await Promise.race([
      work,
      once(signal, "abort", { signal: listening.signal }),
    ]);
  } finally {
    listening.abort();
  }
}

export interface CatalogueOptions {
  path: string;
  readCredential: () => CredentialRead | Promise<CredentialRead>;
  readWindows: ReadAccountWindows;
  offline: boolean;
}

export class ContextCatalogue {
  private readonly options: CatalogueOptions;
  private grant: string | undefined;
  private account: AccountCatalogue | undefined;
  private loading: Promise<AccountLogin | undefined> | undefined;
  private pending: { cancel: AbortController; work: Promise<void> } | undefined;
  private generation = 0;
  private problem: string | undefined;
  private credentialUnreadable = false;
  private source: "saved" | "account" | undefined;

  constructor(options: CatalogueOptions) {
    this.options = options;
  }

  get status(): string {
    const source =
      this.source === "saved"
        ? "Using the saved account catalogue."
        : this.source === "account"
          ? "Using the account catalogue for this session."
          : "Using Pi's configured window until an account window is available.";
    return [
      source,
      this.credentialUnreadable
        ? "Pi’s stored ChatGPT registration could not be read. Reconnect ChatGPT if the error persists."
        : (this.problem ??
          (this.options.offline ? "Pi is offline." : undefined)),
    ]
      .filter((part) => part !== undefined)
      .join(" ");
  }

  window(id: string): number | undefined {
    return this.account?.contextWindows.get(id);
  }

  cancel(): void {
    this.generation++;
    this.loading = undefined;
    this.abortRefresh();
  }

  async checkRegistration(): Promise<void> {
    await this.load();
  }

  async prepare(resolveToken: ResolveAccountToken): Promise<{
    cold: boolean;
    refresh: Promise<void> | undefined;
  }> {
    const generation = this.generation;
    const login = await this.load();
    return {
      cold: this.account === undefined,
      refresh:
        generation === this.generation &&
        login !== undefined &&
        login.grant === this.grant
          ? this.fetchIfDue(login, resolveToken)
          : undefined,
    };
  }

  private abortRefresh(): void {
    this.pending?.cancel.abort();
    this.pending = undefined;
  }

  private async load(): Promise<AccountLogin | undefined> {
    if (this.loading !== undefined) {
      return this.loading;
    }
    const work = this.loadCredential(this.generation);
    this.loading = work;
    try {
      return await work;
    } finally {
      if (this.loading === work) {
        this.loading = undefined;
      }
    }
  }

  private async loadCredential(
    generation: number,
  ): Promise<AccountLogin | undefined> {
    const result = await this.options.readCredential();
    if (generation !== this.generation) {
      return undefined;
    }
    this.credentialUnreadable = result.status === "unavailable";
    if (result.status === "unavailable") {
      return undefined;
    }
    if (result.status === "absent") {
      this.abortRefresh();
      this.grant = undefined;
      this.account = undefined;
      this.source = undefined;
      this.problem = undefined;
      return undefined;
    }

    const grant = grantKey(result.credential.clientId);
    if (this.grant !== grant) {
      this.abortRefresh();
      this.grant = undefined;
      this.account = undefined;
      this.source = undefined;
      this.problem = undefined;
      const saved = await readCatalogue(this.options.path, grant);
      if (generation !== this.generation) {
        return undefined;
      }
      this.grant = grant;
      if (saved !== undefined) {
        const now = Date.now();
        this.account = {
          ...saved,
          refreshAfter:
            saved.refreshAfter > now + refreshIntervalMs
              ? now
              : saved.refreshAfter,
        };
        this.source = "saved";
      }
    }
    return { grant };
  }

  private fetchIfDue(
    login: AccountLogin,
    resolveToken: ResolveAccountToken,
  ): Promise<void> | undefined {
    if (
      this.options.offline ||
      (this.account !== undefined && Date.now() < this.account.refreshAfter)
    ) {
      return undefined;
    }
    if (this.pending !== undefined) {
      return this.pending.work;
    }
    const cancel = new AbortController();
    const signal = AbortSignal.any([
      cancel.signal,
      AbortSignal.timeout(deadlineMs),
    ]);
    const work = waitForRefresh(
      this.refreshCatalogue(login, resolveToken, cancel, signal),
      signal,
    );
    this.pending = { cancel, work };
    return work;
  }

  private async matchesLogin(
    login: AccountLogin,
    token?: string,
  ): Promise<boolean> {
    const current = await this.options.readCredential();
    return (
      current.status === "present" &&
      grantKey(current.credential.clientId) === login.grant &&
      (token === undefined || current.credential.access === token)
    );
  }

  private async requestWindows(
    login: AccountLogin,
    resolveToken: ResolveAccountToken,
    signal: AbortSignal,
  ): Promise<AccountWindowsResult> {
    try {
      signal.throwIfAborted();
      const token = await resolveToken();
      signal.throwIfAborted();
      if (token === undefined || !(await this.matchesLogin(login, token))) {
        return {
          error:
            "Pi could not resolve an access token for the stored ChatGPT registration.",
        };
      }
      signal.throwIfAborted();
      return await this.options.readWindows(token, signal);
    } catch {
      return {
        error: signal.aborted
          ? "The account catalogue request timed out or was cancelled."
          : "Pi could not resolve the ChatGPT login or read its account catalogue.",
      };
    }
  }

  private async refreshCatalogue(
    login: AccountLogin,
    resolveToken: ResolveAccountToken,
    cancel: AbortController,
    signal: AbortSignal,
  ): Promise<void> {
    try {
      const result = await this.requestWindows(login, resolveToken, signal);
      if (
        cancel.signal.aborted ||
        !(await this.matchesLogin(login)) ||
        cancel.signal.aborted
      ) {
        return;
      }

      const account: AccountCatalogue = {
        grant: login.grant,
        contextWindows:
          "windows" in result
            ? result.windows
            : (this.account?.contextWindows ?? new Map()),
        refreshAfter:
          Date.now() +
          ("windows" in result ? refreshIntervalMs : retryIntervalMs),
      };
      this.account = account;
      this.problem = "error" in result ? result.error : undefined;
      if ("windows" in result) {
        this.source = "account";
        await writeCatalogue(this.options.path, account);
      }
    } finally {
      if (this.pending?.cancel === cancel) {
        this.pending = undefined;
      }
    }
  }
}
