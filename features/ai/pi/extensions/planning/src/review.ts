import {
  getSelectListTheme,
  keyHint,
  rawKeyHint,
  type ExtensionContext,
  type ExtensionUIContext,
  type KeybindingsManager,
  type Theme,
} from "@earendil-works/pi-coding-agent";
import {
  getKeybindings,
  getNativeClipboard,
  Image,
  Text,
  VStack,
  type Component,
  type Focusable,
  type TUI,
} from "@earendil-works/pi-tui";
import type { ImageContent } from "@earendil-works/pi-ai";
import type { PlanEditor } from "./editor.ts";
import type { PlanRevision } from "./store.ts";
import { ChoiceInput } from "./ui/choice-input.ts";
import { readClipboardImage } from "./feedback.ts";
import {
  validateFeedbackText,
  validateImageInput,
  validatePlanDocument,
} from "./validation.ts";
import { displayPath, displayText } from "./presentation.ts";

export type ReviewDecision = "current" | "clear" | "revise" | "cancel";
export interface ReviewResult {
  decision: ReviewDecision;
  presentedPlan: PlanRevision;
  feedback?: string;
  images?: ImageContent[];
}
export interface ReviewRequest {
  plan: PlanRevision;
  signal: AbortSignal;
  read(): PlanRevision;
  present(plan: PlanRevision): void;
  readImage?(): Promise<ImageContent>;
}
export type ReviewTerminal = TUI;

type CustomOptions = NonNullable<Parameters<ExtensionUIContext["custom"]>[1]>;

export interface ReviewContext {
  hasUI: boolean;
  mode: ExtensionContext["mode"];
  getContextUsage?: ExtensionContext["getContextUsage"];
  model?: Pick<NonNullable<ExtensionContext["model"]>, "input"> | undefined;
  ui: Pick<
    ExtensionUIContext,
    "select" | "input" | "getToolsExpanded" | "setToolsExpanded"
  > & {
    custom: (
      factory: (
        tui: ReviewTerminal,
        theme: Pick<Theme, "fg">,
        keys: Pick<KeybindingsManager, "matches" | "getKeys">,
        done: (result: ReviewResult) => void,
      ) => Component & Focusable & { dispose(): void },
      options?: Pick<CustomOptions, "blocked">,
    ) => Promise<ReviewResult>;
  };
}

const commentChoice = "Add a comment";
const questionStatus: Pick<CustomOptions, "blocked"> = {
  blocked: { kind: "question", message: "Plan ready for review" },
};
const decisions: { value: ReviewDecision; label: string }[] = [
  { value: "current", label: "Yes, keep context" },
  { value: "clear", label: "Yes, clear context" },
  { value: "revise", label: "No, keep planning" },
  { value: "cancel", label: "Continue planning" },
];

function reviewResult(
  decision: ReviewDecision,
  presentedPlan: PlanRevision,
  feedback?: string,
  images: readonly ImageContent[] = [],
): ReviewResult {
  const result: ReviewResult = { decision, presentedPlan };
  if (decision !== "cancel" && feedback !== undefined) {
    result.feedback = feedback;
  }
  if (decision !== "cancel" && images.length > 0) {
    result.images = images.map(({ type, data, mimeType }) => ({
      type,
      data,
      mimeType,
    }));
  }
  return result;
}

export async function reviewPlan(
  ctx: ReviewContext,
  request: ReviewRequest,
  editor: PlanEditor,
): Promise<ReviewResult> {
  const { signal } = request;
  let presented = request.plan;
  validatePlanDocument(presented);
  request.present(presented);
  if (signal.aborted || !ctx.hasUI) {
    return { decision: "cancel", presentedPlan: presented };
  }
  if (ctx.mode !== "tui") {
    const cancelled: ReviewResult = {
      decision: "cancel",
      presentedPlan: presented,
    };
    const title = `Review plan ${displayPath(presented.path)}\n\n${displayText(presented.content)}`;
    const labels = decisions.map(({ label }) => label);
    let choice = await ctx.ui.select(title, [...labels, commentChoice], {
      signal,
    });
    let feedback: string | undefined;
    if (signal.aborted) {
      return cancelled;
    }
    if (choice === commentChoice) {
      const text = await ctx.ui.input("Add a comment", "Optional feedback", {
        signal,
      });
      if (signal.aborted || typeof text !== "string") {
        return cancelled;
      }
      feedback = text.trim() === "" ? undefined : text;
      choice = await ctx.ui.select(
        `${title}\n\nComment: ${displayText(text)}`,
        labels,
        {
          signal,
        },
      );
    }
    if (signal.aborted) {
      return cancelled;
    }
    const decision =
      decisions.find(({ label }) => label === choice)?.value ?? "cancel";
    if (decision === "cancel") {
      return cancelled;
    }
    if (decision === "revise" && feedback === undefined) {
      const text = await ctx.ui.input(
        "What should Pi change?",
        "Describe the required revisions",
        { signal },
      );
      if (signal.aborted || typeof text !== "string" || text.trim() === "") {
        return cancelled;
      }
      feedback = text;
    }
    validateFeedbackText(feedback);
    return reviewResult(decision, presented, feedback);
  }

  return ctx.ui.custom((tui, theme, keys, done) => {
    let finished = false;
    let editing = false;
    let valid = true;
    let acquiringImage = false;
    let notice: string | undefined;
    const images: ImageContent[] = [];
    const attachments = new VStack();
    const description = new Text("", 1, 0);
    const contextUsage = new Text("", 1, 0);
    const hint = new Text("", 1, 0);
    const warning = new Text("", 1, 0);
    const finish = (decision: ReviewDecision) => {
      if (finished || editing) {
        return;
      }
      if (acquiringImage && decision !== "cancel") {
        notice = "Wait for the clipboard image or cancel review.";
        tui.requestRender();
        return;
      }
      if ((decision === "current" || decision === "clear") && !valid) {
        tui.requestRender();
        return;
      }
      const feedback = choices.text.trim() === "" ? undefined : choices.text;
      try {
        validateFeedbackText(decision === "cancel" ? undefined : feedback);
      } catch (error) {
        notice = String(error);
        tui.requestRender();
        return;
      }
      finished = true;
      signal.removeEventListener("abort", cancel);
      done(reviewResult(decision, presented, feedback, images));
    };
    const cancel = () => {
      if (finished) {
        return;
      }
      finished = true;
      signal.removeEventListener("abort", cancel);
      images.splice(0);
      attachments.clear();
      done({ decision: "cancel", presentedPlan: presented });
    };
    const reload = () => {
      try {
        const next = request.read();
        validatePlanDocument(next);
        valid = true;
        if (
          next.revision !== presented.revision ||
          next.path !== presented.path
        ) {
          presented = next;
          request.present(presented);
          if (valid && notice === undefined) {
            notice = "Plan saved";
          }
        }
      } catch (error) {
        valid = false;
        notice = `Cannot reload the active plan: ${String(error)}`;
      }
    };
    const openEditor = async () => {
      if (finished || editing) {
        return;
      }
      editing = true;
      notice = undefined;
      try {
        tui.stop();
        await editor.open(presented.path);
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
    const attachImage = async (): Promise<void> => {
      if (finished || editing || acquiringImage) {
        return;
      }
      acquiringImage = true;
      try {
        validateImageInput(ctx.model?.input);
        const image = await (request.readImage?.() ??
          readClipboardImage(getNativeClipboard()));
        if (finished || signal.aborted) {
          return;
        }
        images.push(image);
        attachments.addChild(
          new Text(`Image ${images.length} (${image.mimeType})`, 0, 0),
        );
        attachments.addChild(
          new Image(
            image.data,
            image.mimeType,
            {
              fallbackColor: (text) => theme.fg("dim", text),
            },
            { maxHeightCells: 3 },
          ),
        );
        notice = `Attached image ${images.length}`;
        choices.focusInput();
      } catch (error) {
        if (!finished && !signal.aborted) {
          notice = String(error);
        }
      } finally {
        acquiringImage = false;
        if (!finished) {
          tui.requestRender();
        }
      }
    };
    const handleGlobalInput = (input: string): boolean => {
      if (keys.matches(input, "app.clipboard.pasteImage")) {
        attachImage().catch((error: unknown) => {
          if (!finished) {
            notice = String(error);
            tui.requestRender();
          }
        });
        return true;
      }
      if (keys.matches(input, "app.editor.external")) {
        openEditor().catch((error: unknown) => {
          notice = String(error);
          tui.requestRender();
        });
        return true;
      }
      if (getKeybindings().matches(input, "app.tools.expand")) {
        ctx.ui.setToolsExpanded(!ctx.ui.getToolsExpanded());
        return true;
      }
      return false;
    };
    const choices = new ChoiceInput<ReviewDecision>(tui, {
      rows: decisions.map(({ value, label }) => ({
        value,
        label,
        kind: value === "revise" ? "input" : "action",
      })),
      theme: {
        borderColor: (text) => theme.fg("borderMuted", text),
        selectList: getSelectListTheme(),
      },
      onSelect: (decision) => finish(decision),
      onCancel: () => finish("cancel"),
      onInput: handleGlobalInput,
      disabled: () => finished || editing,
      reservedRows: 9,
      additionalContent: attachments,
      hasAdditionalInput: () => images.length > 0,
    });
    class Question extends VStack {
      constructor() {
        super([
          new Text(theme.fg("accent", "Ready to code?"), 1, 0),
          description,
          contextUsage,
          choices,
          hint,
          warning,
        ]);
      }

      get focused(): boolean {
        return choices.focused;
      }

      set focused(value: boolean) {
        choices.focused = value;
      }

      override render(width: number): string[] {
        const percent = ctx.getContextUsage?.()?.percent;
        contextUsage.setText(
          percent !== null && percent !== undefined && Number.isFinite(percent)
            ? theme.fg("dim", `Context: ${percent.toFixed(0)}%`)
            : "",
        );
        const compact = tui.terminal.rows < 16 || width < 50;
        description.setText(
          compact
            ? ""
            : "Pi has written up a plan and is ready to execute. Would you like to proceed?",
        );
        const editorHint = compact
          ? "edit plan"
          : `edit in ${displayText(editor.name)}`;
        const pathHint = compact
          ? ""
          : theme.fg("dim", ` · ${displayPath(presented.path)}`);
        const imageKeys = keys.getKeys("app.clipboard.pasteImage");
        const imageHint =
          !compact && imageKeys.length > 0
            ? "  " + rawKeyHint(imageKeys.join("/"), "attach image")
            : "";
        const editorKeys =
          width < 30 && tui.terminal.rows < 14
            ? ""
            : "  " +
              keyHint("tui.select.confirm", "confirm") +
              "  " +
              rawKeyHint(
                keys.getKeys("app.editor.external").join("/"),
                editorHint,
              );
        hint.setText(
          keyHint("tui.input.tab", "feedback") +
            editorKeys +
            pathHint +
            imageHint,
        );
        warning.setText(
          notice === undefined ? "" : theme.fg("dim", displayText(notice)),
        );
        return super.render(width);
      }

      handleInput(input: string): void {
        choices.handleInput(input);
        tui.requestRender();
      }

      dispose(): void {
        finished = true;
        images.splice(0);
        attachments.clear();
        signal.removeEventListener("abort", cancel);
      }
    }
    const question = new Question();
    signal.addEventListener("abort", cancel, { once: true });
    if (signal.aborted) {
      cancel();
    }
    return question;
  }, questionStatus);
}
