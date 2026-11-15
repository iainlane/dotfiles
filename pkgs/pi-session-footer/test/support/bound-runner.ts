import type {
  ExtensionActions,
  ExtensionContextActions,
  ExtensionRunner,
  SessionManager,
} from "@earendil-works/pi-coding-agent";

type Model = ReturnType<ExtensionContextActions["getModel"]>;

function unavailable(): never {
  throw new Error("The fixture runner does not implement this action");
}

const actions: ExtensionActions = {
  sendMessage: unavailable,
  sendUserMessage: unavailable,
  appendEntry: unavailable,
  setSessionName: unavailable,
  getSessionName: unavailable,
  setLabel: unavailable,
  getActiveTools: unavailable,
  getAllTools: unavailable,
  getSettings: unavailable,
  setActiveTools: unavailable,
  refreshTools: unavailable,
  getCommands: unavailable,
  setModel: unavailable,
  getThinkingLevel: () => "high",
  setThinkingLevel: unavailable,
};

/**
 * Binds `runner` as a Pi mode does. Contexts from the runner call `model` on
 * every read of `ctx.model`, so a context already passed to an extension also
 * reports a later model. Entries that extensions append go to `session`, as
 * Pi appends them to the current session.
 */
export function bindModel(
  runner: ExtensionRunner,
  model: () => Model,
  session?: Pick<SessionManager, "appendCustomEntry">,
): void {
  const appendEntry: ExtensionActions["appendEntry"] =
    session === undefined
      ? unavailable
      : (customType, data) => {
          session.appendCustomEntry(customType, data);
        };

  runner.bindCore(
    { ...actions, appendEntry },
    {
      getModel: model,
      getScopedModels: () => [],
      isIdle: () => true,
      isProjectTrusted: () => true,
      getSignal: () => {},
      abort: () => {},
      hasPendingMessages: () => false,
      shutdown: () => {},
      getContextUsage: () => {},
      compact: () => {},
      getSystemPrompt: () => "",
    },
  );
}
