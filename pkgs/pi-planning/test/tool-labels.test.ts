import { mkdtemp, rm } from "node:fs/promises";
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
  type ToolRendererResolver,
} from "@earendil-works/pi-coding-agent";
import { TuiAltScreen } from "@earendil-works/pi-tui";
import { beforeAll, expect, it } from "vitest";
import { TestTerminal } from "./terminal.ts";
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
