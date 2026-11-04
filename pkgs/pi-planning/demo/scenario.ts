import type {
  AssistantMessage,
  Context,
  ToolCall,
} from "@earendil-works/pi-ai/compat";

export const researchMessage =
  "This is a scripted offline provider. I will inspect the cleanup command first.";

export const initialProgram = `import { readdir, unlink } from "node:fs/promises";

const candidates = (await readdir("scratch")).filter((path) =>
  path.endsWith(".tmp"),
);

for (const path of candidates) {
  await unlink("scratch/" + path);
}

console.log("Removed: " + candidates.join(", "));
`;

export const implementation = `import { readdir, unlink } from "node:fs/promises";
import { parseArgs } from "node:util";

const { values } = parseArgs({
  options: { "dry-run": { type: "boolean", default: false } },
});
const candidates = (await readdir("scratch")).filter((path) =>
  path.endsWith(".tmp"),
);

for (const path of candidates) {
  if (values["dry-run"]) {
    console.log("Would remove: scratch/" + path);
    continue;
  }

  await unlink("scratch/" + path);
  console.log("Removed: scratch/" + path);
}
`;

export const draftPlan = `# Preview cleanup before deleting files

## Goal

Add \`--dry-run\` to the cleanup CLI.
Preview the same files that normal cleanup would remove.

## Existing behaviour

- The CLI scans the scratch directory.
- Files ending in .tmp are removed.
- Other files remain untouched.

## Proposed change

1. Parse a boolean --dry-run option with Node's parseArgs.
2. Collect candidates through the existing filter.
3. Print each candidate when preview mode is enabled.
4. Skip unlink for every previewed file.
5. Keep normal cleanup behaviour unchanged.

## Scope

- Change cleanup.mjs only.
- Add no dependencies.
- Keep output paths relative to the working directory.
- Preserve the current session and its plan file.

## Verification

- Run node cleanup.mjs --dry-run.
- Check that scratch/cache.tmp still exists.
`;

export const editorAddition = "- Verify dry-run never removes a file.\n";
export const reviewComment = "Preserve the existing command-line interface.";

export class DemoScenario {
  private phase = 0;

  constructor(private readonly planPath: string) {}

  private result(
    messages: Context["messages"],
    id: string,
    isError = false,
  ): void {
    const result = messages.findLast(
      (entry) => entry.role === "toolResult" && entry.toolCallId === id,
    );
    if (result?.role !== "toolResult" || result.isError !== isError) {
      throw new Error(
        `The demo expected ${id} to ${isError ? "be blocked" : "succeed"}.`,
      );
    }
  }

  private static tool(
    id: string,
    name: string,
    args: ToolCall["arguments"],
  ): AssistantMessage["content"] {
    return [{ type: "toolCall", id, name, arguments: args }];
  }

  next(messages: Context["messages"]): AssistantMessage["content"] {
    switch (this.phase++) {
      case 0:
        return DemoScenario.tool("enter", "enter_plan_mode", {});
      case 1:
        this.result(messages, "enter");
        return [
          { type: "text", text: researchMessage },
          ...DemoScenario.tool("inspect", "read", { path: "cleanup.mjs" }),
        ];
      case 2:
        this.result(messages, "inspect");
        return DemoScenario.tool("premature-edit", "write", {
          path: "cleanup.mjs",
          content: implementation,
        });
      case 3:
        this.result(messages, "premature-edit", true);
        return [
          {
            type: "text",
            text: "Plan mode blocked the project edit. Only the plan file can change before approval.",
          },
          ...DemoScenario.tool("draft", "write", {
            path: this.planPath,
            content: draftPlan,
          }),
        ];
      case 4:
        this.result(messages, "draft");
        return DemoScenario.tool("review", "submit_plan", {});
      case 5:
        this.result(messages, "review");
        return [
          {
            type: "text",
            text: "The revised plan is approved. Waiting for the same-session context reset.",
          },
        ];
      case 6: {
        const context = JSON.stringify(messages);
        if (
          context.includes(researchMessage) ||
          !context.includes(editorAddition.trim()) ||
          !context.includes(reviewComment)
        ) {
          throw new Error(
            "The demo requires cleared research context and the edited, approved plan with review feedback.",
          );
        }
        return [
          {
            type: "text",
            text: "Research context cleared. The edited plan and review comment are still attached, and the session is unchanged.",
          },
          ...DemoScenario.tool("implement", "write", {
            path: "cleanup.mjs",
            content: implementation,
          }),
        ];
      }
      case 7:
        this.result(messages, "implement");
        return DemoScenario.tool("verify", "bash", {
          command:
            "node cleanup.mjs --dry-run && test -f scratch/cache.tmp && printf 'Preview left cache.tmp untouched.\\n'",
        });
      default:
        this.result(messages, "verify");
        return [
          {
            type: "text",
            text: "Implemented the approved plan. The dry-run check passed, and cache.tmp is untouched.\n\nOffline demo complete.",
          },
        ];
    }
  }
}
