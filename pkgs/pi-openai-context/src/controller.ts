import type { Api, Model } from "@earendil-works/pi-ai";
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import type { ContextCatalogue, ResolveAccountToken } from "./catalogue.ts";
import { openaiBaseUrl, openaiProvider } from "./catalogue-client.ts";
import { adjustContext, type ContextPolicy, restoreContext } from "./model.ts";

type Boundary = "selection" | "input" | "run-start";
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
  acceptsAccountWindow(model: Model<Api>): boolean;
  resolveAccountToken: ResolveAccountToken;
}

interface ControllerOptions {
  catalogue: Pick<
    ContextCatalogue,
    "prepare" | "checkRegistration" | "window" | "status" | "cancel"
  >;
  controls: ModelControls;
  readPolicy: (id: string) => Promise<ContextPolicy>;
}

function isOpenAIResponsesModel(
  model: ExtensionContext["model"],
): model is Model<"openai-responses"> {
  return (
    model?.provider === openaiProvider &&
    model.api === "openai-responses" &&
    model.baseUrl === openaiBaseUrl
  );
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

  async status(ctx: ContextModelSession): Promise<string> {
    const active = ctx.model;
    if (!isOpenAIResponsesModel(active)) {
      return "Select an OpenAI Responses model to see its context window.";
    }
    const window = `${active.id} uses a ${active.contextWindow.toLocaleString()}-token context window.`;
    if (this.failedModel === active) {
      return `${window} Pi could not update the active model.`;
    }
    if (!ctx.managesModel(active.id)) {
      return `${window} Using the limits from the model provider.`;
    }
    const policy = await this.options.readPolicy(active.id);
    if (policy.kind === "unavailable") {
      return `${window} The extension could not read models.json.`;
    }
    if (
      policy.kind === "override" &&
      adjustContext(active, policy.limits, "override") === undefined
    ) {
      return `${window} The configured context window leaves no room for input.`;
    }
    if (policy.kind !== "automatic" || !ctx.acceptsAccountWindow(active)) {
      return `${window} Using Pi's configured limits.`;
    }
    const { catalogue } = this.options;
    await catalogue.checkRegistration();
    const advertised = catalogue.window(active.id);
    const detail =
      advertised === undefined
        ? "The account catalogue has no window for this model."
        : advertised <= active.maxTokens
          ? "The advertised window leaves no room for input."
          : advertised === active.contextWindow
            ? "The window matches the account catalogue."
            : "The account catalogue advertises a different window.";
    return `${window} ${detail} ${catalogue.status}`;
  }

  async apply(ctx: ContextModelSession, boundary: Boundary): Promise<void> {
    const active = ctx.model;
    const signal = this.shutdown.signal;
    if (
      signal.aborted ||
      !isOpenAIResponsesModel(active) ||
      (boundary !== "run-start" && !ctx.isIdle())
    ) {
      return;
    }

    const operation = ++this.operation;
    const isCurrent = () =>
      !signal.aborted &&
      this.operation === operation &&
      ctx.model === active &&
      (boundary === "run-start" || ctx.isIdle());
    const policy = ctx.managesModel(active.id)
      ? await this.options.readPolicy(active.id)
      : ({ kind: "configured" } as const);
    if (!isCurrent()) {
      return;
    }

    const { catalogue } = this.options;
    if (policy.kind === "automatic" && ctx.acceptsAccountWindow(active)) {
      const { cold, refresh } = await catalogue.prepare(() =>
        ctx.resolveAccountToken(),
      );
      if (!isCurrent()) {
        return;
      }
      if (cold && boundary === "run-start") {
        await refresh;
      }
    }

    if (!isCurrent()) {
      return;
    }
    let next = restoreContext(active);
    if (ctx.managesModel(active.id)) {
      if (policy.kind === "override") {
        next =
          adjustContext(active, policy.limits, "override") ??
          restoreContext(active, "account");
      }
      if (policy.kind === "unavailable") {
        next = restoreContext(active, "account");
      }
      if (policy.kind === "automatic" && ctx.acceptsAccountWindow(active)) {
        const window = catalogue.window(active.id);
        if (window !== undefined) {
          next =
            adjustContext(active, { contextWindow: window }, "account") ?? next;
        }
      }
    }
    await this.replaceModel(ctx, active, next, signal, operation);
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
