import type { Api, Model } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { once } from "node:events";
import { expect, it } from "vitest";
import {
  ContextController,
  type ContextModelSession,
} from "#openai-context/controller.ts";
import type { ContextPolicy } from "#openai-context/model.ts";

const base: Model<"openai-responses"> = {
  id: "sol",
  provider: "openai",
  api: "openai-responses",
  baseUrl: "https://api.openai.com/v1",
  name: "Fixture Sol",
  contextWindow: 272_000,
  maxTokens: 32_000,
  reasoning: true,
  input: ["text"],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
};
const configured = { ...base, contextWindow: 200_000, maxTokens: 40_000 };
const alternate = { ...base, id: "alternate" };
const accountWindow = 500_000;
type ThinkingLevel = ReturnType<ExtensionAPI["getThinkingLevel"]>;

function createSession() {
  let model: Model<Api> = base;
  let thinking: ThinkingLevel = "high";
  let policy: ContextPolicy = { kind: "automatic" };
  let eligible = true;
  let idle = true;
  let modelUpdate: "apply" | "decline" | "throw" = "apply";
  let refresh: Promise<void> | undefined;
  const catalogueEvents = new EventTarget();
  let window: number | undefined = accountWindow;

  const session: ContextModelSession = {
    get model() {
      return model;
    },
    isIdle: () => idle,
    managesModel: (id) => id === base.id,
    acceptsAccountWindow: () => eligible,
    resolveAccountToken: async () => "fixture",
  };
  const createController = () =>
    new ContextController({
      catalogue: {
        async prepare() {
          catalogueEvents.dispatchEvent(new Event("prepare"));
          return { cold: window === undefined, refresh };
        },
        checkRegistration: async () => {},
        window: () => window,
        status: "Fixture catalogue.",
        cancel() {},
      },
      controls: {
        async setModel(next) {
          if (modelUpdate === "throw") {
            throw new Error("Pi lost the login before changing the model.");
          }
          if (modelUpdate === "decline") {
            return false;
          }
          model = next;
          thinking = "low";
          return true;
        },
        getThinkingLevel: () => thinking,
        setThinkingLevel(next) {
          thinking = next;
        },
      },
      readPolicy: async () => policy,
    });
  return {
    controller: createController(),
    createController,
    session,
    get active() {
      return { model, thinking };
    },
    configure(next = configured) {
      policy = {
        kind: "override",
        limits: {
          contextWindow: next.contextWindow,
          maxTokens: next.maxTokens,
        },
      };
    },
    clearConfiguration() {
      policy = { kind: "automatic" };
    },
    useApiKey() {
      eligible = false;
    },
    rejectConfiguration() {
      policy = { kind: "unavailable" };
    },
    becomeBusy() {
      idle = false;
    },
    select(next: Model<Api>) {
      model = next;
    },
    rejectChanges(how: "decline" | "throw") {
      modelUpdate = how;
    },
    delayCatalogue() {
      const responses = new EventTarget();
      window = undefined;
      const update = async () => {
        await once(responses, "reply");
        window = accountWindow;
      };
      refresh = update();
      return {
        preparing: () => once(catalogueEvents, "prepare"),
        deliver: () => responses.dispatchEvent(new Event("reply")),
      };
    },
  };
}

it.each([false, true])(
  "applies a live override before compaction with prior adjustment %s",
  async (adjusted) => {
    const host = createSession();
    if (adjusted) {
      await host.controller.apply(host.session, "selection");
    }
    host.configure();
    await host.controller.apply(host.session, "input");
    expect(host.active).toStrictEqual({ model: configured, thinking: "high" });

    host.clearConfiguration();
    await host.controller.apply(host.session, "run-start");
    expect(host.active).toStrictEqual({
      model: { ...base, contextWindow: accountWindow },
      thinking: "high",
    });
  },
);

it("restores the registry model when the session switches to an API key", async () => {
  const host = createSession();
  await host.controller.apply(host.session, "selection");
  host.useApiKey();
  await host.controller.apply(host.session, "input");
  expect(host.active).toStrictEqual({ model: base, thinking: "high" });
});

it("does not wait for the account request during input handling", async () => {
  const host = createSession();
  const { deliver } = host.delayCatalogue();
  await host.controller.apply(host.session, "input");
  expect(host.active).toStrictEqual({ model: base, thinking: "high" });

  const running = host.controller.apply(host.session, "run-start");
  deliver();
  await running;
  expect(host.active).toStrictEqual({
    model: { ...base, contextWindow: accountWindow },
    thinking: "high",
  });
});

it.each(["switch", "shutdown"] as const)(
  "ignores a cold result after %s",
  async (change) => {
    const host = createSession();
    const { deliver, preparing } = host.delayCatalogue();
    const prepared = preparing();
    const running = host.controller.apply(host.session, "run-start");
    await prepared;
    if (change === "switch") {
      host.select(alternate);
    } else {
      host.controller.cancel();
      host.controller.start();
    }
    deliver();
    await running;
    expect(host.active).toStrictEqual({
      model: change === "switch" ? alternate : base,
      thinking: "high",
    });
  },
);

it.each(["decline", "throw"] as const)(
  "reports a model update that ends with %s",
  async (how) => {
    const host = createSession();
    host.becomeBusy();
    await host.controller.apply(host.session, "input");
    const whileBusy = host.active;
    host.rejectChanges(how);
    await host.controller.apply(host.session, "run-start");
    expect({ whileBusy, declined: host.active }).toStrictEqual({
      whileBusy: { model: base, thinking: "high" },
      declined: { model: base, thinking: "high" },
    });
    expect(await host.controller.status(host.session)).toContain(
      "Pi could not update the active model.",
    );
  },
);

it("restores the original window after an extension reload and loss of the OAuth login", async () => {
  const host = createSession();
  const selected = {
    ...base,
    maxTokens: 42_000,
    headers: { "X-Fixture": "custom" },
  };
  host.select(selected);
  await host.controller.apply(host.session, "selection");
  const adjusted = host.active;
  host.useApiKey();
  const reloaded = host.createController();
  // The SDK keeps the current model while replacing the extension instance.
  await reloaded.apply(host.session, "selection");
  expect({ adjusted, restored: host.active }).toStrictEqual({
    adjusted: {
      model: { ...selected, contextWindow: accountWindow },
      thinking: "high",
    },
    restored: { model: selected, thinking: "high" },
  });
});

it("removes a live override after Pi reloads extensions", async () => {
  const host = createSession();
  host.configure();
  await host.controller.apply(host.session, "selection");
  host.clearConfiguration();
  const reloaded = host.createController();
  await reloaded.apply(host.session, "selection");
  expect(host.active).toStrictEqual({
    model: { ...base, contextWindow: accountWindow },
    thinking: "high",
  });
});

it("keeps the last explicit window while the config file cannot be read", async () => {
  const host = createSession();
  host.configure();
  await host.controller.apply(host.session, "selection");
  host.rejectConfiguration();
  await host.controller.apply(host.session, "input");
  expect(host.active).toStrictEqual({ model: configured, thinking: "high" });
});

it("describes a configured window that is too small for its output limit", async () => {
  const host = createSession();
  host.configure({ ...configured, contextWindow: 20_000 });
  await host.controller.apply(host.session, "input");
  expect(host.active).toStrictEqual({ model: base, thinking: "high" });
  expect(await host.controller.status(host.session)).toContain(
    "The configured context window leaves no room for input.",
  );
});

it("keeps session-specific headers when applying an explicit window", async () => {
  const host = createSession();
  const headers = { "X-Fixture": "custom" };
  host.select({ ...base, headers });
  host.configure();
  await host.controller.apply(host.session, "input");
  expect(host.active).toStrictEqual({
    model: { ...configured, headers },
    thinking: "high",
  });
});
