import { fileURLToPath } from "node:url";
import {
  DefaultResourceLoader,
  ExtensionRunner,
  ModelRegistry,
  ModelRuntime,
  SessionManager,
  SettingsManager,
  createEventBus,
  type EventBus,
  type ExtensionAPI,
  type ExtensionCommandContext,
} from "@earendil-works/pi-coding-agent";

export async function runtimeFixture(events: EventBus = createEventBus()) {
  const cwd = "/nonexistent-footer-fixture";
  let api: ExtensionAPI | undefined;
  const loader = new DefaultResourceLoader({
    cwd,
    agentDir: cwd,
    eventBus: events,
    settingsManager: SettingsManager.inMemory(),
    noExtensions: true,
    noSkills: true,
    noThemes: true,
    additionalThemePaths: [
      fileURLToPath(
        new URL(
          "./modes/interactive/theme/dark.json",
          import.meta.resolve("@earendil-works/pi-coding-agent"),
        ),
      ),
    ],
    noPromptTemplates: true,
    noContextFiles: true,
    extensionFactories: [
      (value) => {
        api = value;
      },
    ],
  });

  await loader.reload();

  if (api === undefined) {
    throw new Error("Expected the SDK to initialise the fixture extension");
  }

  const models = await ModelRuntime.create({
    authPath: `${cwd}/auth.json`,
    modelsPath: null,
    refreshOnCreate: false,
  });
  const { extensions, runtime } = loader.getExtensions();
  runtime.getThinkingLevel = () => "high";
  const runner = new ExtensionRunner(
    extensions,
    runtime,
    cwd,
    SessionManager.inMemory(cwd),
    new ModelRegistry(models),
  );

  const context = runner.createContext();
  const theme = loader.getThemes().themes[0];

  if (theme === undefined) {
    throw new Error("Expected the SDK fixture theme");
  }
  const model = models.getModels()[0];

  if (model === undefined) {
    throw new Error("Expected a built-in model for the SDK fixture");
  }

  const commandContext: ExtensionCommandContext = {
    ...context,
    mode: "tui",
    ui: { ...context.ui, theme },
    model: {
      ...model,
      id: "fixture",
      provider: "openai-codex",
      contextWindow: 200_000,
    },
    thinkingLevel: "high",
    getSystemPromptOptions: () => ({ cwd }),
    waitForIdle: async () => {},
    newSession: async () => ({ cancelled: false }),
    fork: async () => ({ cancelled: false }),
    navigateTree: async () => ({ cancelled: false }),
    switchSession: async () => ({ cancelled: false }),
    reload: async () => {},
  };

  return { api, context: commandContext, runner };
}
