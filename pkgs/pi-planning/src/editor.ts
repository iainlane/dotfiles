import { spawn } from "node:child_process";
import type {
  ExtensionContext,
  ExtensionUIContext,
} from "@earendil-works/pi-coding-agent";
import type { Component, TUI } from "@earendil-works/pi-tui";
import { basename } from "node:path";
import { forEachChild, parse, type SyntaxNode } from "unbash";
import { errorText } from "./presentation.ts";

export interface PlanEditor {
  name: string;
  open(path: string): Promise<void>;
}

type EditorTerminal = Pick<TUI, "stop" | "start" | "requestRender">;

const literalNodes = new Set([
  "Command",
  "Word",
  "Literal",
  "SingleQuoted",
  "DoubleQuoted",
]);

function editorArguments(source: string): {
  executable: string;
  args: string[];
} {
  const script = parse(source);
  const statement = script.commands[0];
  const command = statement?.command;
  if (
    (script.errors?.length ?? 0) > 0 ||
    script.commands.length !== 1 ||
    statement?.background === true ||
    command?.type !== "Command" ||
    command.name?.value === undefined ||
    command.name.value === "" ||
    command.prefix.length > 0
  ) {
    throw new Error(
      "Configure the editor as one executable with literal arguments.",
    );
  }
  let literal = true;
  const visit = (node: SyntaxNode): void => {
    if (!literalNodes.has(node.type)) {
      literal = false;
    }
    forEachChild(node, visit);
  };
  visit(command);
  if (!literal) {
    throw new Error(
      "Editor commands cannot include shell expansion or redirection. Use an editor wrapper script if needed.",
    );
  }
  return {
    executable: command.name.value,
    args: command.args.map((argument) => {
      if (argument.type !== "Word") {
        throw new Error("Editor arguments must be literal words.");
      }
      return argument.value;
    }),
  };
}

export function editorName(command: string): string {
  try {
    return basename(editorArguments(command).executable);
  } catch {
    return "the configured editor";
  }
}

async function openPlanEditorInTerminal(
  tui: EditorTerminal,
  path: string,
  command: string,
): Promise<void> {
  tui.stop();
  try {
    await openPlanEditor(path, command);
  } finally {
    tui.start();
    tui.requestRender(true);
  }
}

export async function openPlanEditorInUi(
  ctx: Pick<ExtensionContext, "hasUI" | "mode"> & {
    ui: Pick<ExtensionUIContext, "notify"> & {
      custom: (
        factory: (
          tui: EditorTerminal,
          theme: unknown,
          keys: unknown,
          done: (failure: Error | undefined) => void,
        ) => Component & { dispose(): void },
      ) => Promise<Error | undefined>;
    };
  },
  path: string,
  command: string,
): Promise<void> {
  if (!ctx.hasUI || ctx.mode !== "tui") {
    throw new Error(
      "Opening the plan in an external editor requires Pi's terminal UI.",
    );
  }
  const failure = await ctx.ui.custom((tui, _theme, _keys, done) => {
    let live = true;
    const edit = async (): Promise<void> => {
      if (!live) {
        return;
      }
      let error: Error | undefined;
      try {
        await openPlanEditorInTerminal(tui, path, command);
      } catch (cause) {
        error = cause instanceof Error ? cause : new Error(String(cause));
      }
      if (!live) {
        return;
      }
      try {
        done(error);
      } catch (cause) {
        ctx.ui.notify(
          `Cannot restore the plan editor UI: ${errorText(cause)}`,
          "error",
        );
      }
    };
    queueMicrotask(() => {
      void edit();
    });
    return {
      render: () => [],
      invalidate() {},
      dispose() {
        live = false;
      },
    };
  });
  if (failure) {
    throw failure;
  }
}

export async function openPlanEditor(
  path: string,
  command: string,
): Promise<void> {
  const { executable, args } = editorArguments(command);
  await new Promise<void>((resolve, reject) => {
    const editor = spawn(executable, [...args, path], { stdio: "inherit" });
    editor.once("error", (error) =>
      reject(
        new Error(
          `Cannot start editor ${executable}. Check externalEditor, VISUAL or EDITOR.`,
          { cause: error },
        ),
      ),
    );
    editor.once("close", (code, signal) => {
      if (code !== 0) {
        reject(
          new Error(
            `The editor exited with ${signal ?? `status ${String(code)}`}. Use a wait-capable editor command.`,
          ),
        );
        return;
      }
      resolve();
    });
  });
}
