import type {
  AssistantMessage,
  Context,
  ToolCall,
  ToolResultMessage,
} from "@earendil-works/pi-ai/compat";
import { Type } from "typebox";
import { Check } from "typebox/value";
import { expect, it } from "vitest";
import { DemoScenario } from "#demo/scenario.ts";

const planPath = "/demo/plans/session.md";
// The demo tape types these into the plan editor and the review comment.
const editorAddition = "- Verify dry-run never removes a file.\n";
const reviewComment = "Preserve the existing command-line interface.";

const writeSchema = Type.Object({ content: Type.String() });

function result(id: string, isError = false): ToolResultMessage {
  return {
    role: "toolResult",
    toolCallId: id,
    toolName: id,
    content: [{ type: "text", text: "Fixture result" }],
    isError,
    timestamp: 1,
  };
}

function written(call: ToolCall | undefined): string {
  const args: unknown = call?.arguments;
  if (!Check(writeSchema, args)) {
    throw new Error("Expected a scripted write.");
  }
  return args.content;
}

function throughApproval() {
  const scenario = new DemoScenario(planPath);
  const messages: Context["messages"] = [];
  const replies: AssistantMessage["content"][] = [];
  for (const isError of [false, false, true, false, false]) {
    const content = scenario.next(messages);
    replies.push(content);
    const call = content.find((entry) => entry.type === "toolCall");
    if (call?.type !== "toolCall") {
      throw new Error("Expected a scripted tool call.");
    }
    messages.push(result(call.id, isError));
  }
  scenario.next(messages);
  const calls = replies.flatMap((content) =>
    content.flatMap((entry) => (entry.type === "toolCall" ? [entry] : [])),
  );
  const text = replies.flatMap((content) =>
    content.flatMap((entry) => (entry.type === "text" ? [entry.text] : [])),
  );
  return {
    scenario,
    calls,
    research: text[0] ?? "",
    implementation: written(calls[2]),
    draft: written(calls[3]),
  };
}

it("uses the actual planning and file tools before approval", () => {
  const { calls, implementation, draft } = throughApproval();
  expect({
    calls,
    previewOption: implementation.includes('values["dry-run"]'),
    draftTitle: draft.split("\n", 1)[0],
  }).toStrictEqual({
    calls: [
      { type: "toolCall", id: "enter", name: "enter_plan_mode", arguments: {} },
      {
        type: "toolCall",
        id: "inspect",
        name: "read",
        arguments: { path: "cleanup.mjs" },
      },
      {
        type: "toolCall",
        id: "premature-edit",
        name: "write",
        arguments: { path: "cleanup.mjs", content: implementation },
      },
      {
        type: "toolCall",
        id: "draft",
        name: "write",
        arguments: { path: planPath, content: draft },
      },
      { type: "toolCall", id: "review", name: "submit_plan", arguments: {} },
    ],
    previewOption: true,
    draftTitle: "# Preview cleanup before deleting files",
  });
});

it("continues from the edited plan after cleared research context", () => {
  const { scenario, implementation, draft } = throughApproval();
  const implement = scenario.next([
    {
      role: "user",
      content: draft + editorAddition + reviewComment,
      timestamp: 1,
    },
  ]);
  const verify = scenario.next([result("implement")]);
  const finished = scenario.next([result("verify")]);
  expect({ implement, verify, finished }).toStrictEqual({
    implement: [
      {
        type: "text",
        text: "Research context cleared. The edited plan and review comment are still attached, and the session is unchanged.",
      },
      {
        type: "toolCall",
        id: "implement",
        name: "write",
        arguments: { path: "cleanup.mjs", content: implementation },
      },
    ],
    verify: [
      {
        type: "toolCall",
        id: "verify",
        name: "bash",
        arguments: {
          command:
            "node cleanup.mjs --dry-run && test -f scratch/cache.tmp && printf 'Preview left cache.tmp untouched.\\n'",
        },
      },
    ],
    finished: [
      {
        type: "text",
        text: "Implemented the approved plan. The dry-run check passed, and cache.tmp is untouched.\n\nOffline demo complete.",
      },
    ],
  });
});

it.each([
  {
    description: "missing saved edit",
    parts: ["draft", "comment"],
  },
  {
    description: "missing review feedback",
    parts: ["draft", "addition"],
  },
  {
    description: "retained research",
    parts: ["draft", "addition", "comment", "research"],
  },
] as const)(
  "refuses to fake successful context clearing: $description",
  ({ parts }) => {
    const { scenario, draft, research } = throughApproval();
    const text = {
      draft,
      addition: editorAddition,
      comment: reviewComment,
      research,
    };
    const content = parts.map((part) => text[part]).join("");
    expect(() =>
      scenario.next([{ role: "user", content, timestamp: 1 }]),
    ).toThrow("cleared research context and the edited, approved plan");
  },
);

it("fails if Plan mode did not block the project edit", () => {
  const scenario = new DemoScenario(planPath);
  scenario.next([]);
  scenario.next([result("enter")]);
  scenario.next([result("inspect")]);
  expect(() => scenario.next([result("premature-edit")])).toThrow(
    "expected premature-edit to be blocked",
  );
});
