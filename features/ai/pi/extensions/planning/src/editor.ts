import { spawn } from "node:child_process";
import { forEachChild, parse, type SyntaxNode } from "unbash";

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
