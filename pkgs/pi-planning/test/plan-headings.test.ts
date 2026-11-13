import { homedir } from "node:os";
import { join } from "node:path";
import type {
  ToolCallLabelContext,
  ToolRendererResolver,
} from "@earendil-works/pi-coding-agent";
import { expect, it, vi } from "vitest";
import { registerPlanHeadings } from "#planning/plan-headings.ts";

const cwd = join(homedir(), "heading-fixture");
const directory = join(cwd, "agent", "plans");

it.each([
  {
    tool: "write",
    args: { path: `${directory}/draft.md` },
    label: "Updated plan",
  },
  {
    tool: "edit",
    args: { path: "agent/plans/draft.md" },
    label: "Updated plan",
  },
  {
    tool: "write",
    args: { path: `@${directory}/draft.md` },
    label: "Updated plan",
  },
  {
    tool: "edit",
    args: { path: "~/heading-fixture/agent/plans/draft.md" },
    label: "Updated plan",
  },
  {
    tool: "write",
    args: { path: `${directory}/draft\u00A0name.md` },
    label: "Updated plan",
  },
  {
    tool: "write",
    args: { file_path: `${directory}/legacy.md` },
    label: "Updated plan",
  },
  {
    tool: "write",
    args: { path: `${directory}-other/draft.md` },
    label: "Delegated heading",
  },
  {
    tool: "edit",
    args: { path: "agent/plans/../../project.ts" },
    label: "Delegated heading",
  },
  { tool: "write", args: { path: directory }, label: "Delegated heading" },
  { tool: "write", args: {}, label: "Delegated heading" },
  { tool: "write", args: { path: 42 }, label: "Delegated heading" },
  {
    tool: "write",
    args: {
      path: "project.ts",
      file_path: `${directory}/not-the-execution-target.md`,
    },
    label: "Delegated heading",
  },
  {
    tool: "apply_patch",
    args: { path: `${directory}/draft.md` },
    label: "Delegated heading",
  },
])(
  "composes a lexical plan heading for $tool $args",
  ({ tool, args, label }) => {
    const resolvers: ToolRendererResolver[] = [];
    registerPlanHeadings(
      {
        registerToolRenderer: (resolver) => {
          resolvers.push(resolver);
        },
      },
      directory,
    );
    const resolver = resolvers[0];
    if (!resolver) {
      throw new Error("Expected a planning heading resolver");
    }
    const previous = vi.fn<
      (args: unknown, context: ToolCallLabelContext) => string
    >(() => "Delegated heading");
    const renderers = {
      renderShell: "self",
      resolveCallLabel: previous,
    } as const;
    const resolved = resolver(tool, () => renderers);
    expect({
      label: resolved?.resolveCallLabel?.(args, { toolName: tool, cwd }),
      shell: resolved?.renderShell,
      delegated: previous.mock.calls,
    }).toStrictEqual({
      label,
      shell: "self",
      delegated:
        label === "Updated plan" ? [] : [[args, { toolName: tool, cwd }]],
    });
  },
);
