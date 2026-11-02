import type {
  Context,
  ToolCall,
  ToolResultMessage,
} from "@earendil-works/pi-ai/compat";
import { expect, it } from "vitest";
import {
  DemoScenario,
  draftPlan,
  editorAddition,
  implementation,
  researchMessage,
  reviewComment,
} from "../demo/scenario.ts";

const planPath = "/demo/plans/session.md";

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

function throughApproval() {
  const scenario = new DemoScenario(planPath);
  const messages: Context["messages"] = [];
  const calls: ToolCall[] = [];
  for (const isError of [false, false, true, false, false]) {
    const content = scenario.next(messages);
    const call = content.find((entry) => entry.type === "toolCall");
    if (call?.type !== "toolCall") {
      throw new Error("Expected a scripted tool call.");
    }
    calls.push(call);
    messages.push(result(call.id, isError));
  }
  scenario.next(messages);
  return { scenario, calls };
}

it("uses the actual planning and file tools before approval", () => {
  expect(throughApproval().calls).toStrictEqual([
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
      arguments: { path: planPath, content: draftPlan },
    },
    { type: "toolCall", id: "review", name: "submit_plan", arguments: {} },
  ]);
});

it("continues from the edited plan after cleared research context", () => {
  const { scenario } = throughApproval();
  const implement = scenario.next([
    {
      role: "user",
      content: draftPlan + editorAddition + reviewComment,
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
  { description: "missing saved edit", content: draftPlan + reviewComment },
  {
    description: "missing review feedback",
    content: draftPlan + editorAddition,
  },
  {
    description: "retained research",
    content: draftPlan + editorAddition + reviewComment + researchMessage,
  },
])(
  "refuses to fake successful context clearing: $description",
  ({ content }) => {
    const { scenario } = throughApproval();
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
