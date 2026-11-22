import type { Api, Model } from "@earendil-works/pi-ai";
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import type {
  CatalogueRefreshResult,
  ContextCatalogue,
  ResolveAccountToken,
} from "./catalogue.ts";
import {
  adjustContext,
  isOpenAIResponsesModel,
  type ContextPolicy,
  restoreContext,
} from "./model.ts";

type Boundary = "selection" | "input" | "run-start";
type StatusField = [label: string, value: string];
interface ModelControls extends Pick<
  ExtensionAPI,
  "getThinkingLevel" | "setThinkingLevel"
> {
  setModel(model: Model<Api>): Promise<boolean>;
}

export interface ContextModelSession extends Pick<
  ExtensionContext,
  "model" | "isIdle"
> {
  managesModel(id: string): boolean;
  acceptsAccountWindows(): boolean;
  publishAccountWindows(
    windows: ContextCatalogue["windows"],
    isCurrent: () => boolean,
  ): Promise<void>;
  resolveAccountToken: ResolveAccountToken;
}

interface ControllerOptions {
  catalogue: Pick<
    ContextCatalogue,
    | "prepare"
    | "refreshNow"
    | "checkRegistration"
    | "window"
    | "windows"
    | "status"
    | "cancel"
  >;
  controls: ModelControls;
  readPolicy: (id: string) => Promise<ContextPolicy>;
}

export class ContextController {
  private readonly options: ControllerOptions;
  private shutdown = new AbortController();
  private operation = 0;
  private failedModel: Model<Api> | undefined;

  constructor(options: ControllerOptions) {
    this.options = options;
  }

  start(): void {
    if (this.shutdown.signal.aborted) {
      this.shutdown = new AbortController();
      this.failedModel = undefined;
    }
  }

  cancel(): void {
    this.shutdown.abort();
    this.options.catalogue.cancel();
  }

  async refresh(
    ctx: ContextModelSession,
  ): Promise<CatalogueRefreshResult | undefined> {
    const signal = this.shutdown.signal;
    if (signal.aborted) {
      return undefined;
    }
    if (!ctx.acceptsAccountWindows()) {
      return {
        error:
          "Use /login openai to sign in with ChatGPT before refreshing the account catalogue.",
      };
    }

    const catalogue = this.options.catalogue;
    const result = await catalogue.refreshNow(ctx.resolveAccountToken);
    if (signal.aborted) {
      return undefined;
    }
    if ("error" in result) {
      return result;
    }
    if (!ctx.acceptsAccountWindows()) {
      return { error: "The ChatGPT sign-in changed during the refresh." };
    }
    if (ctx.isIdle()) {
      await this.apply(ctx, "selection");
    } else {
      await ctx.publishAccountWindows(
        catalogue.windows,
        () => !signal.aborted && ctx.acceptsAccountWindows(),
      );
    }
    if (signal.aborted) {
      return undefined;
    }
    if (ctx.model !== undefined && this.failedModel === ctx.model) {
      return {
        error:
          "The account catalogue refreshed. Pi could not update the active model.",
      };
    }
    return result;
  }

  async status(ctx: ContextModelSession): Promise<string> {
    const active = ctx.model;
    if (!isOpenAIResponsesModel(active)) {
      return "Select an OpenAI Responses model to see its context window.";
    }
    const report = (...details: StatusField[]) => {
      const fields: StatusField[] = [
        ["Model", `${active.provider}/${active.id}`],
        ["Context window", `${active.contextWindow.toLocaleString()} tokens`],
        ...details,
      ];
      const width = Math.max(...fields.map(([label]) => label.length));
      return fields
        .map(([label, value]) => `${label.padEnd(width)}  ${value}`)
        .join("\n");
    };
    if (this.failedModel === active) {
      return report(["Status", "Pi could not update the active model."]);
    }
    if (!ctx.managesModel(active.id)) {
      return report(["Source", "Model provider"]);
    }
    const policy = await this.options.readPolicy(active.id);
    if (policy.kind === "unavailable") {
      return report(["Status", "The extension could not read models.json."]);
    }
    if (
      policy.kind === "override" &&
      adjustContext(active, policy.limits, "override") === undefined
    ) {
      return report([
        "Status",
        "The configured context window leaves no room for input.",
      ]);
    }
    if (policy.kind !== "automatic") {
      return report(["Source", "models.json"]);
    }
    if (!ctx.acceptsAccountWindows()) {
      return report(["Source", "Pi configuration"]);
    }
    const { catalogue } = this.options;
    await catalogue.checkRegistration();
    const advertised = catalogue.window(active.id);
    const { source, notice } = catalogue.status;
    const saved = source === "saved" ? " (saved catalogue)" : "";
    const details: StatusField[] = [
      [
        "Account context",
        advertised === undefined
          ? "Unavailable"
          : `${advertised.toLocaleString()} tokens${saved}`,
      ],
    ];
    const diagnostics = [
      advertised !== undefined && advertised <= active.maxTokens
        ? "The account window leaves no room for input with the current output limit."
        : undefined,
      notice,
    ].filter((message) => message !== undefined);
    if (diagnostics.length > 0) {
      details.push(["Status", diagnostics.join(" ")]);
    }
    return report(...details);
  }

  async apply(ctx: ContextModelSession, boundary: Boundary): Promise<void> {
    const active = ctx.model;
    const signal = this.shutdown.signal;
    if (signal.aborted || (boundary !== "run-start" && !ctx.isIdle())) {
      return;
    }

    const operation = ++this.operation;
    const isLatest = () => !signal.aborted && this.operation === operation;
    const isCurrent = (model = active) =>
      isLatest() &&
      ctx.model === model &&
      (boundary === "run-start" || ctx.isIdle());
    const policy =
      isOpenAIResponsesModel(active) && ctx.managesModel(active.id)
        ? await this.options.readPolicy(active.id)
        : ({ kind: "configured" } as const);
    if (!isCurrent()) {
      return;
    }

    const { catalogue } = this.options;
    let refresh: Promise<CatalogueRefreshResult> | undefined;
    if (ctx.acceptsAccountWindows()) {
      const preparation = await catalogue.prepare(ctx.resolveAccountToken);
      refresh = preparation.refresh;
      if (
        isCurrent() &&
        boundary === "run-start" &&
        policy.kind === "automatic" &&
        preparation.cold
      ) {
        await refresh;
        refresh = undefined;
      }
    }

    if (!isCurrent()) {
      return;
    }
    const publish = (windows: ContextCatalogue["windows"]) =>
      ctx.publishAccountWindows(
        ctx.acceptsAccountWindows() ? windows : undefined,
        isLatest,
      );
    const windows = catalogue.windows;
    await publish(windows);
    if (!isCurrent()) {
      return;
    }
    let expectedModel = active;
    if (isOpenAIResponsesModel(active)) {
      const next = this.resolveModel(
        active,
        policy,
        ctx.acceptsAccountWindows() ? windows?.get(active.id) : undefined,
      );
      await this.replaceModel(ctx, active, next, signal, operation);
      expectedModel = ctx.model === next ? next : active;
    }
    if (refresh === undefined) {
      return;
    }

    const applyRefreshedWindows = async (
      pending: Promise<CatalogueRefreshResult>,
    ) => {
      try {
        await pending;
        if (!isLatest() || windows === catalogue.windows) {
          return;
        }
        if (
          active !== undefined &&
          policy.kind === "automatic" &&
          isCurrent(expectedModel) &&
          catalogue.window(active.id) !== windows?.get(active.id)
        ) {
          await this.apply(ctx, "selection");
          return;
        }
        await publish(catalogue.windows);
      } catch {
        if (isCurrent(expectedModel)) {
          this.failedModel = expectedModel;
        }
      }
    };
    void applyRefreshedWindows(refresh);
  }

  private resolveModel(
    active: Model<Api>,
    policy: ContextPolicy,
    accountWindow: number | undefined,
  ): Model<Api> {
    if (policy.kind === "override") {
      return (
        adjustContext(active, policy.limits, "override") ??
        restoreContext(active, "account")
      );
    }
    if (policy.kind === "unavailable") {
      return restoreContext(active, "account");
    }
    if (policy.kind === "automatic" && accountWindow !== undefined) {
      return (
        adjustContext(active, { contextWindow: accountWindow }, "account") ??
        restoreContext(active)
      );
    }
    return restoreContext(active);
  }

  private async replaceModel(
    ctx: ContextModelSession,
    active: Model<Api>,
    next: Model<Api>,
    signal: AbortSignal,
    operation: number,
  ): Promise<void> {
    if (
      next === active ||
      signal.aborted ||
      ctx.model !== active ||
      this.operation !== operation
    ) {
      return;
    }
    const { controls } = this.options;
    const thinking = controls.getThinkingLevel();
    let updated = false;
    try {
      updated = await controls.setModel(next);
    } catch {
      // Pi checks for configured authentication again before changing the model.
    }
    if (!signal.aborted && this.operation === operation) {
      this.failedModel = updated ? undefined : active;
      if (
        updated &&
        ctx.model === next &&
        controls.getThinkingLevel() !== thinking
      ) {
        controls.setThinkingLevel(thinking);
      }
    }
  }
}
