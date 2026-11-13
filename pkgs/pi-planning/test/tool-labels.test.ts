import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { stripVTControlCharacters } from "node:util";
import {
  createAgentSession,
  DefaultResourceLoader,
  initTheme,
  ModelRuntime,
  SessionManager,
  SettingsManager,
  ToolExecutionComponent,
  type AgentSession,
  type ToolCallLabelContext,
  type ToolRenderers,
  type ToolRendererResolver,
} from "@earendil-works/pi-coding-agent";
import { TuiAltScreen, type Component } from "@earendil-works/pi-tui";
import { beforeAll, expect, it, vi } from "vitest";
import { TestTerminal, untilRendered } from "./terminal.ts";
import { registerPlanHeadings } from "#planning/plan-headings.ts";

let session: AgentSession | undefined;
let directory: string;

beforeAll(async () => {
  directory = await mkdtemp(join(tmpdir(), "pi-native-headings-"));
  const settings = SettingsManager.inMemory({ compaction: { enabled: false } });
  const loader = new DefaultResourceLoader({
    cwd: directory,
    agentDir: directory,
    settingsManager: settings,
    noExtensions: true,
    noSkills: true,
    noThemes: true,
    noPromptTemplates: true,
    noContextFiles: true,
  });
  await loader.reload();
  const runtime = await ModelRuntime.create({
    authPath: join(directory, "auth.json"),
    modelsPath: join(directory, "models.json"),
  });
  ({ session } = await createAgentSession({
    cwd: directory,
    agentDir: directory,
    resourceLoader: loader,
    modelRuntime: runtime,
    settingsManager: settings,
    sessionManager: SessionManager.inMemory(),
  }));
  initTheme("dark", false);
  return async () => {
    session?.dispose();
    await rm(directory, { recursive: true, force: true });
  };
});

function definition(tool: string) {
  const registered = session?.getToolDefinition(tool);
  if (registered === undefined) {
    throw new Error(`Expected the native ${tool} definition`);
  }
  return registered;
}

function visible(component: ToolExecutionComponent): string {
  return component
    .render(100)
    .map((line) => stripVTControlCharacters(line))
    .join("\n");
}

it.each(["write", "edit"] as const)(
  "resolves a display-only %s call label with captured arguments and cwd",
  (toolName) => {
    const cwd = "/fixture/captured";
    const args = {
      path: "plans/draft.md",
      ...(toolName === "write" ? { content: "Preserved preview" } : {}),
    };
    const resolveCallLabel = vi.fn<
      (args: unknown, context: ToolCallLabelContext) => string
    >(() => "Updated plan");
    const base = definition(toolName);
    const execute = vi.spyOn(base, "execute");
    try {
      const component = new ToolExecutionComponent(
        toolName,
        "identity",
        args,
        {},
        { ...base, resolveCallLabel },
        new TuiAltScreen(new TestTerminal()),
        cwd,
      );
      const output = visible(component);
      expect({
        title: output.includes("Updated plan"),
        path: output.includes("plans/draft.md"),
        label: component.getCallLabel(),
        resolution: resolveCallLabel.mock.calls,
        execution: execute.mock.calls,
      }).toStrictEqual({
        title: true,
        path: true,
        label: "Updated plan",
        resolution: [[args, { toolName, cwd }]],
        execution: [],
      });
    } finally {
      execute.mockRestore();
    }
  },
);

it.each(["write", "edit"] as const)(
  "falls back to the native %s heading when label resolution fails",
  (toolName) => {
    const args = { path: "missing.md", content: "Preserved preview" };
    const component = new ToolExecutionComponent(
      toolName,
      "identity",
      args,
      {},
      {
        ...definition(toolName),
        resolveCallLabel: () => {
          throw new Error("Broken extension resolver");
        },
      },
      new TuiAltScreen(new TestTerminal()),
      directory,
    );
    expect({
      label: component.getCallLabel(),
      heading: visible(component)
        .split("\n")
        .some((line) => line.trimStart().startsWith(`${toolName} `)),
      preview:
        toolName === "edit" || visible(component).includes("Preserved preview"),
    }).toStrictEqual({ label: undefined, heading: true, preview: true });
  },
);

it("preserves the native Edit preview, state and component through the result rebuild", async () => {
  const path = join(directory, "draft.md");
  await writeFile(path, "before\n");
  const args = { path, edits: [{ oldText: "before", newText: "after" }] };
  const base = definition("edit");
  const call = base.renderCall;
  const result = base.renderResult;
  if (call === undefined || result === undefined) {
    throw new Error("Expected native Edit renderers");
  }
  const components: Component[] = [];
  const states: unknown[] = [];
  const labels: (string | undefined)[] = [];
  const renderers: ToolRenderers = {
    ...base,
    resolveCallLabel: () => "Updated plan",
    renderCall: (input, theme, context) => {
      const component = call(input, theme, context);
      components.push(component);
      states.push(context.state);
      labels.push(context.callLabel);
      return component;
    },
    renderResult: (output, options, theme, context) => {
      states.push(context.state);
      labels.push(context.callLabel);
      return result(output, options, theme, context);
    },
  };
  const screen = new TuiAltScreen(new TestTerminal());
  const component = new ToolExecutionComponent(
    "edit",
    "native-edit",
    args,
    {},
    renderers,
    screen,
    directory,
  );
  component.setExpanded(true);
  component.setArgsComplete();
  await untilRendered(screen, () => visible(component).includes("after"));
  component.updateResult(
    {
      content: [],
      details: { diff: "-1 before\n+1 result-after", firstChangedLine: 1 },
      isError: false,
    },
    false,
  );
  const output = visible(component);
  expect({
    title: output.includes("Updated plan"),
    result: output.includes("result-after"),
    identity: components.every((previous) => previous === components[0]),
    state: new Set(states).size,
    labels: [...new Set(labels)],
  }).toStrictEqual({
    title: true,
    result: true,
    identity: true,
    state: 1,
    labels: ["Updated plan"],
  });
});

it.each(["write", "edit"] as const)(
  "recomputes %s headings for streamed arguments, settled results and replay",
  (tool) => {
    let policy: ToolRendererResolver | undefined;
    registerPlanHeadings(
      {
        registerToolRenderer: (resolver) => {
          policy = resolver;
        },
      },
      join(directory, "plans"),
    );
    if (policy === undefined) {
      throw new Error("Expected a planning heading resolver");
    }
    const renderers = policy(tool, () => definition(tool));
    const make = (args: unknown) =>
      new ToolExecutionComponent(
        tool,
        "recorded-identity",
        args,
        {},
        renderers,
        new TuiAltScreen(new TestTerminal()),
        directory,
      );
    const component = make({
      path: "project.ts",
      content: "Unchanged content",
    });
    const snapshot = () => ({
      label: component.getCallLabel(),
      heading: visible(component).includes("Updated plan"),
    });
    const states = [snapshot()];
    const args = { path: "plans/nonexistent.md", content: "Unchanged content" };
    component.updateArgs(args);
    states.push(snapshot());
    component.setExpanded(true);
    component.updateResult({ content: [], isError: false }, false);
    states.push(snapshot());
    component.updateResult(
      { content: [{ type: "text", text: "Fixture failure" }], isError: true },
      false,
    );
    states.push(snapshot());
    component.setExpanded(false);
    component.updateArgs({ path: "plans-other/draft.md" });
    states.push(snapshot());
    const replay = make(args);
    replay.updateResult({ content: [], isError: false }, false);
    expect({
      states,
      replay: {
        label: replay.getCallLabel(),
        heading: visible(replay).includes("Updated plan"),
      },
      args,
    }).toStrictEqual({
      states: [
        undefined,
        "Updated plan",
        "Updated plan",
        "Updated plan",
        undefined,
      ].map((label) => ({ label, heading: label !== undefined })),
      replay: { label: "Updated plan", heading: true },
      args: { path: "plans/nonexistent.md", content: "Unchanged content" },
    });
  },
);
