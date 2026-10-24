import {
  type ExtensionContext,
  type ExtensionUIContext,
} from "@earendil-works/pi-coding-agent";
import {
  matchesKey,
  truncateToWidth,
  type Component,
  type TUI,
} from "@earendil-works/pi-tui";
import type { PlanRevision } from "./store.ts";

export type ReviewDecision = "current" | "fresh" | "revise" | "cancel";

export interface ReviewContext {
  hasUI: boolean;
  mode: ExtensionContext["mode"];
  ui: Pick<ExtensionUIContext, "select"> & {
    custom: (
      factory: (
        tui: Pick<TUI, "requestRender"> & {
          terminal: Pick<TUI["terminal"], "rows">;
        },
        theme: unknown,
        keys: unknown,
        done: (decision: ReviewDecision) => void,
      ) => Component & { handleInput(input: string): void; dispose(): void },
    ) => Promise<ReviewDecision>;
  };
}

export type ReviewDocument = Pick<Component, "render" | "invalidate">;

export async function reviewPlan(
  ctx: ReviewContext,
  plan: PlanRevision,
  signal: AbortSignal,
  createDocument: (content: string) => ReviewDocument,
): Promise<ReviewDecision> {
  if (signal.aborted || !ctx.hasUI) {
    return "cancel";
  }
  if (ctx.mode !== "tui") {
    const choice = await ctx.ui.select(
      `Review plan ${plan.path}\nRevision ${plan.revision}\n\n${plan.content}`,
      [
        "Approve in current conversation",
        "Approve in a fresh conversation",
        "Revise the plan",
      ],
      { signal },
    );
    if (signal.aborted) {
      return "cancel";
    }
    return choice === "Approve in current conversation"
      ? "current"
      : choice === "Approve in a fresh conversation"
        ? "fresh"
        : choice === "Revise the plan"
          ? "revise"
          : "cancel";
  }

  return ctx.ui.custom((tui, _theme, _keys, done) => {
    const document = createDocument(plan.content);
    let offset = 0;
    let finished = false;
    const finish = (decision: ReviewDecision) => {
      if (finished) {
        return;
      }
      finished = true;
      signal.removeEventListener("abort", cancel);
      done(decision);
    };
    const cancel = () => finish("cancel");
    signal.addEventListener("abort", cancel, { once: true });
    if (signal.aborted) {
      cancel();
    }

    return {
      render(width) {
        const lines = document.render(width);
        const height = Math.max(3, tui.terminal.rows - 7);
        offset = Math.max(0, Math.min(offset, lines.length - height));
        return [
          truncateToWidth(`Plan: ${plan.path}`, width),
          truncateToWidth(`Revision: ${plan.revision}`, width),
          "",
          ...lines.slice(offset, offset + height),
          "",
          truncateToWidth(
            "↑/↓ scroll · a approve · f approve in fresh conversation · r revise · Esc cancel",
            width,
          ),
        ];
      },
      handleInput(input) {
        if (matchesKey(input, "escape")) {
          finish("cancel");
        } else if (input === "a") {
          finish("current");
        } else if (input === "f") {
          finish("fresh");
        } else if (input === "r") {
          finish("revise");
        } else if (matchesKey(input, "up")) {
          offset--;
        } else if (matchesKey(input, "down")) {
          offset++;
        } else if (matchesKey(input, "pageUp")) {
          offset -= Math.max(3, tui.terminal.rows - 7);
        } else if (matchesKey(input, "pageDown")) {
          offset += Math.max(3, tui.terminal.rows - 7);
        }
        tui.requestRender();
      },
      invalidate() {
        document.invalidate();
      },
      dispose() {
        signal.removeEventListener("abort", cancel);
      },
    };
  });
}
