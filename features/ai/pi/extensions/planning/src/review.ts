import {
  getSelectListTheme,
  type ExtensionContext,
  type ExtensionUIContext,
  type KeybindingsManager,
  type Theme,
} from "@earendil-works/pi-coding-agent";
import {
  matchesKey,
  SelectList,
  truncateToWidth,
  type Component,
  type KeyId,
  type TUI,
} from "@earendil-works/pi-tui";
import type { PlanRevision } from "./store.ts";

export type ReviewDecision = "current" | "clear" | "revise" | "cancel";
export interface ReviewResult {
  decision: ReviewDecision;
  presentedPlan: PlanRevision;
}
export interface ReviewRequest {
  plan: PlanRevision;
  signal: AbortSignal;
  read(): PlanRevision;
  present(plan: PlanRevision): void;
}
export type ReviewTerminal = Pick<TUI, "requestRender" | "stop" | "start"> & {
  terminal: Pick<TUI["terminal"], "rows">;
};

export interface ReviewContext {
  hasUI: boolean;
  mode: ExtensionContext["mode"];
  ui: Pick<ExtensionUIContext, "select"> & {
    custom: (
      factory: (
        tui: ReviewTerminal,
        theme: Pick<Theme, "fg">,
        keys: Pick<KeybindingsManager, "matches" | "getKeys">,
        done: (result: ReviewResult) => void,
      ) => Component & { dispose(): void },
    ) => Promise<ReviewResult>;
  };
}

const decisions: { value: ReviewDecision; label: string; key: KeyId }[] = [
  { value: "current", label: "Approve and keep context", key: "a" },
  { value: "clear", label: "Approve and clear context", key: "c" },
  { value: "revise", label: "Revise the plan", key: "r" },
  { value: "cancel", label: "Continue planning", key: "escape" },
];

export async function reviewPlan(
  ctx: ReviewContext,
  request: ReviewRequest,
  edit: (path: string) => Promise<void>,
): Promise<ReviewResult> {
  const { signal } = request;
  let presented = request.plan;
  request.present(presented);
  if (signal.aborted || !ctx.hasUI) {
    return { decision: "cancel", presentedPlan: presented };
  }
  if (ctx.mode !== "tui") {
    const choice = await ctx.ui.select(
      `Review plan ${presented.path}\nRevision ${presented.revision}\n\n${presented.content}`,
      decisions.slice(0, 3).map(({ label }) => label),
      { signal },
    );
    const decision = signal.aborted
      ? "cancel"
      : (decisions.find(({ label }) => label === choice)?.value ?? "cancel");
    return { decision, presentedPlan: presented };
  }

  return ctx.ui.custom((tui, theme, keys, done) => {
    let finished = false;
    let editing = false;
    let valid = true;
    let notice: string | undefined;
    let headerHeight = 3;
    let visibleChoices = 4;
    let list = makeList(visibleChoices);
    const finish = (decision: ReviewDecision) => {
      if (finished || editing) {
        return;
      }
      if ((decision === "current" || decision === "clear") && !valid) {
        tui.requestRender();
        return;
      }
      finished = true;
      signal.removeEventListener("abort", cancel);
      done({ decision, presentedPlan: presented });
    };
    const cancel = () => {
      if (finished) {
        return;
      }
      finished = true;
      signal.removeEventListener("abort", cancel);
      done({ decision: "cancel", presentedPlan: presented });
    };
    function makeList(height: number): SelectList {
      const choices = decisions.map(({ value, label, key }) => ({
        value,
        label: `[${key === "escape" ? "Esc" : key}] ${label}`,
      }));
      const next = new SelectList(choices, height, getSelectListTheme());
      next.onSelect = ({ value }) => {
        const decision = decisions.find((item) => item.value === value)?.value;
        if (decision !== undefined) {
          finish(decision);
        }
      };
      next.onCancel = () => finish("cancel");
      return next;
    }
    const reload = () => {
      try {
        const next = request.read();
        valid =
          next.content.trim() !== "" &&
          next.content !==
            "# Implementation plan\n\nDraft the recommended approach here.\n";
        if (!valid) {
          notice = "Write an implementation plan before approval.";
        }
        if (
          next.revision !== presented.revision ||
          next.path !== presented.path
        ) {
          presented = next;
          request.present(presented);
        }
      } catch (error) {
        valid = false;
        notice = `Cannot reload the active plan: ${String(error)}`;
      }
      list.setSelectedIndex(decisions.length - 1);
    };
    const openEditor = async () => {
      if (finished || editing) {
        return;
      }
      editing = true;
      notice = undefined;
      try {
        tui.stop();
        await edit(presented.path);
      } catch (error) {
        notice = String(error);
      } finally {
        editing = false;
        if (!finished) {
          reload();
        }
        tui.start();
        tui.requestRender(true);
      }
    };
    signal.addEventListener("abort", cancel, { once: true });
    if (signal.aborted) {
      cancel();
    }

    return {
      render(width) {
        const compact = tui.terminal.rows < 12;
        const header = [theme.fg("accent", "Approve this plan?")];
        if (!compact) {
          header.push(
            `Plan: ${presented.path}`,
            `Revision: ${presented.revision}`,
          );
        }
        headerHeight = header.length;
        const height = Math.max(1, Math.min(4, tui.terminal.rows - 8));
        if (height !== visibleChoices) {
          const selected = list.getSelectedItem()?.value;
          list = makeList(height);
          list.setSelectedIndex(
            Math.max(
              0,
              decisions.findIndex(({ value }) => value === selected),
            ),
          );
          visibleChoices = height;
        }
        const editorKeys = keys.getKeys("app.editor.external").join("/");
        return [
          ...header.map((line) => truncateToWidth(line, width)),
          ...list.render(width),
          truncateToWidth(
            `Page Up/Down or wheel: review · ${editorKeys}: edit · Enter: choose · Esc: cancel`,
            width,
          ),
          ...(notice === undefined
            ? []
            : [truncateToWidth(theme.fg("error", notice), width)]),
        ];
      },
      handleInput(input) {
        if (finished) {
          return;
        }
        if (keys.matches(input, "app.editor.external")) {
          openEditor().catch((error: unknown) => {
            notice = String(error);
            tui.requestRender();
          });
          return;
        }
        if (editing) {
          return;
        }
        const decision = decisions.find(({ key }) => matchesKey(input, key));
        if (decision) {
          finish(decision.value);
        } else {
          list.handleInput(input);
        }
        tui.requestRender();
      },
      handleMouse(event) {
        return finished ||
          editing ||
          event.type === "wheel" ||
          event.y < headerHeight
          ? undefined
          : list.handleMouse({ ...event, y: event.y - headerHeight });
      },
      invalidate() {
        list.invalidate();
      },
      dispose() {
        finished = true;
        signal.removeEventListener("abort", cancel);
      },
    };
  });
}
