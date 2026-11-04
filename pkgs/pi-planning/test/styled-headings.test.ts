import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { stripVTControlCharacters } from "node:util";
import {
  createAgentSession,
  DefaultResourceLoader,
  initTheme,
  keyHint,
  keyText,
  ModelRuntime,
  SessionManager,
  SettingsManager,
  ToolExecutionComponent,
  type ToolRenderers,
} from "@earendil-works/pi-coding-agent";
import { TuiAltScreen, type Component } from "@earendil-works/pi-tui";
import { expect, it, vi } from "vitest";
import { TestTerminal, untilRendered } from "./terminal.ts";

interface RendererTrace {
  native: Component[];
  styled: Component[];
  states: unknown[];
}

function visible(component: Component): string {
  return component
    .render(100)
    .map((line) => stripVTControlCharacters(line))
    .join("\n");
}

it.each([
  "planning-pretty",
  "pretty-planning",
  "diff-planning",
  "planning-diff",
  "diff-pretty-planning",
  "diff-planning-pretty",
  "pretty-diff-planning",
  "pretty-planning-diff",
  "planning-diff-pretty",
  "planning-pretty-diff",
])(
  "composes file-tool renderers with planning in %s load order",
  async (order) => {
    const pretty = process.env.PI_TEST_PRETTY;
    if (pretty === undefined || pretty === "") {
      throw new Error(
        "Set PI_TEST_PRETTY to the packaged pi-pretty directory.",
      );
    }
    const diff = process.env.PI_TEST_DIFF;
    if (diff === undefined || diff === "") {
      throw new Error("Set PI_TEST_DIFF to the packaged pi-diff directory.");
    }
    const withDiff = order.includes("diff");
    const withPretty = order.includes("pretty");
    const cwd = await mkdtemp(join(tmpdir(), "pi-styled-headings-"));
    const agentDir = join(cwd, "agent");
    vi.stubEnv("PI_CODING_AGENT_DIR", agentDir);
    vi.stubEnv("PRETTY_CONFIG_DIR", agentDir);
    vi.stubEnv("PI_OFFLINE", "1");
    let session:
      | Awaited<ReturnType<typeof createAgentSession>>["session"]
      | undefined;
    try {
      await mkdir(agentDir);
      await writeFile(
        join(agentDir, "pi-pretty.json"),
        JSON.stringify({ toolStyle: "claudecode" }),
      );
      const planning = fileURLToPath(new URL("../index.ts", import.meta.url));
      const grouping = join(cwd, "grouping.ts");
      await writeFile(
        grouping,
        `import pretty from ${JSON.stringify(join(pretty, "src/index.js"))}; import { installClaudeChatGrouping } from ${JSON.stringify(join(pretty, "src/claude-style.js"))}; import { Container } from "@earendil-works/pi-tui"; export default async function(pi) { await pretty(pi); installClaudeChatGrouping(true); pi.registerEntryRenderer("fixture-group", entry => { const group = new Container(); for (const component of entry.data) group.addChild(component); return group; }); pi.on("session_shutdown", () => installClaudeChatGrouping(false)); }`,
      );
      const extensions = new Map([
        ["planning", planning],
        ["pretty", grouping],
        ["diff", join(diff, "src/extension.ts")],
      ]);
      const settings = SettingsManager.inMemory({
        compaction: { enabled: false },
      });
      const loader = new DefaultResourceLoader({
        cwd,
        agentDir,
        settingsManager: settings,
        noExtensions: true,
        noSkills: true,
        noThemes: true,
        noPromptTemplates: true,
        noContextFiles: true,
        additionalExtensionPaths: order.split("-").map((name) => {
          const path = extensions.get(name);
          if (path === undefined) {
            throw new Error(`Unknown fixture extension: ${name}`);
          }
          return path;
        }),
      });
      await loader.reload();
      expect(loader.getExtensions().errors).toStrictEqual([]);
      const runtime = await ModelRuntime.create({
        authPath: join(cwd, "auth.json"),
        modelsPath: join(cwd, "models.json"),
      });
      ({ session } = await createAgentSession({
        cwd,
        agentDir,
        resourceLoader: loader,
        modelRuntime: runtime,
        settingsManager: settings,
        sessionManager: SessionManager.create(cwd, join(cwd, "sessions")),
      }));
      const runner = session.extensionRunner;
      initTheme("dark", false);
      runner.setUIContext(runner.getUIContext(), "tui");
      await runner.emit({ type: "agent_start" });
      const nativeSession = session;
      const components = new Map<string, ToolExecutionComponent>();
      const screens = new Map<string, TuiAltScreen>();
      const traces = new Map<string, RendererTrace>();
      const rows = (["write", "edit"] as const).map((tool) => {
        const args = {
          path: join(agentDir, "plans", "missing.md"),
          ...(tool === "write" ? { content: "Exact preview" } : {}),
        };
        const base = nativeSession.getToolDefinition(tool);
        const call = base?.renderCall;
        if (call === undefined) {
          throw new Error(`Expected the native ${tool} call renderer`);
        }
        const trace: RendererTrace = { native: [], styled: [], states: [] };
        traces.set(tool, trace);
        const delegated: ToolRenderers = {
          ...base,
          renderCall: (input, theme, context) => {
            const component = call(input, theme, context);
            trace.native.push(component);
            trace.states.push(context.state);
            return component;
          },
        };
        const renderers = runner.resolveToolRenderers(tool, () => delegated);
        const styledCall = renderers?.renderCall;
        if (styledCall === undefined) {
          throw new Error(`Expected styled ${tool} call rendering`);
        }
        const instrumented: ToolRenderers = {
          ...renderers,
          renderCall: (input, theme, context) => {
            const component = styledCall(input, theme, context);
            trace.styled.push(component);
            return component;
          },
        };
        const screen = new TuiAltScreen(new TestTerminal());
        const component = new ToolExecutionComponent(
          tool,
          `${tool}-identity`,
          args,
          {},
          instrumented,
          screen,
          cwd,
        );
        components.set(tool, component);
        screens.set(tool, screen);
        const output = visible(component);
        return {
          tool,
          shell: renderers?.renderShell,
          label: component.getCallLabel(),
          heading: output.includes("Updated plan"),
          styled: output.includes("· Updated plan"),
        };
      });
      const groupingRenderer = runner.getEntryRenderer("fixture-group");
      const group = groupingRenderer?.(
        {
          type: "custom",
          id: "grouping",
          parentId: null,
          timestamp: new Date(0).toISOString(),
          customType: "fixture-group",
          data: [...components.values()],
        },
        { expanded: false, keyText, keyHint },
        runner.createContext().ui.theme,
      );
      const grouped = group
        ?.render(100)
        .map((line) => stripVTControlCharacters(line))
        .find((line) => line.includes("Running"));
      expect({
        rows,
        summary: grouped?.includes("Updated plan"),
      }).toStrictEqual({
        rows: ["write", "edit"].map((tool) => ({
          tool,
          shell: withPretty ? "self" : "default",
          label: "Updated plan",
          heading: true,
          styled: withPretty,
        })),
        summary: withPretty ? true : undefined,
      });

      const edit = components.get("edit");
      const editScreen = screens.get("edit");
      const trace = traces.get("edit");
      if (
        edit === undefined ||
        editScreen === undefined ||
        trace === undefined
      ) {
        throw new Error("Expected an instrumented Edit component");
      }
      await mkdir(join(agentDir, "plans"));
      const path = join(agentDir, "plans", "draft.md");
      await writeFile(path, "before\n");
      const args = { path, edits: [{ oldText: "before", newText: "after" }] };
      edit.updateArgs(args);
      edit.setExpanded(true);
      edit.setArgsComplete();
      const pendingPreview = withDiff ? "Updated plan" : "after";
      await untilRendered(editScreen, () =>
        visible(edit).includes(pendingPreview),
      );
      edit.updateResult(
        {
          content: [],
          details: withDiff
            ? {
                patch: `--- ${path}\n+++ ${path}\n@@ -1 +1 @@\n-before\n+result-after\n`,
              }
            : { diff: "-1 before\n+1 result-after", firstChangedLine: 1 },
          isError: false,
        },
        false,
      );
      edit.setExpanded(false);
      const collapsed = visible(edit);
      edit.setExpanded(true);
      await untilRendered(editScreen, () =>
        visible(edit).includes("result-after"),
      );
      const expanded = visible(edit);
      expect({
        collapsed: collapsed.includes("Updated plan"),
        expanded: expanded.includes("Updated plan"),
        diff: expanded.includes("result-after"),
        nativeIdentity: trace.native.every(
          (component) => component === trace.native[0],
        ),
        styledIdentity: trace.styled.every(
          (component) => component === trace.styled[0],
        ),
        state: new Set(trace.states).size,
        args,
      }).toStrictEqual({
        collapsed: true,
        expanded: true,
        diff: true,
        nativeIdentity: true,
        styledIdentity: true,
        state: 1,
        args: { path, edits: [{ oldText: "before", newText: "after" }] },
      });
    } finally {
      await session?.extensionRunner.emit({
        type: "session_shutdown",
        reason: "quit",
      });
      session?.dispose();
      vi.unstubAllEnvs();
      await rm(cwd, { recursive: true, force: true });
    }
  },
);
