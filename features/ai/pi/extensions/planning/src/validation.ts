import type { PlanRevision } from "./store.ts";

export const maxPlanCodeUnits = 200_000;
export const maxFeedbackCodeUnits = 200_000;

export class PlanValidationError extends Error {
  override readonly name = "PlanValidationError";
}

export function decodePlanText(bytes: Uint8Array): string {
  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(
      bytes,
    );
  } catch (cause) {
    throw new PlanValidationError("The plan is not valid UTF-8 text.", {
      cause,
    });
  }
}

export function validateInlinePlanText(content: string): void {
  if (content.length > maxPlanCodeUnits) {
    throw new PlanValidationError(
      "Plans are limited to 200,000 UTF-16 code units for inline review. Shorten the plan before requesting approval.",
    );
  }
  if (Buffer.from(content, "utf8").toString("utf8") !== content) {
    throw new PlanValidationError("The plan contains invalid Unicode text.");
  }
}

export function validateFeedbackText(feedback: string | undefined): void {
  if (feedback === undefined) {
    return;
  }
  if (feedback.length > maxFeedbackCodeUnits) {
    throw new PlanValidationError(
      "Feedback is limited to 200,000 UTF-16 code units. Shorten the feedback before submitting it.",
    );
  }
  if (Buffer.from(feedback, "utf8").toString("utf8") !== feedback) {
    throw new PlanValidationError("Feedback contains invalid Unicode text.");
  }
}

export function validateImageInput(input: readonly string[] | undefined): void {
  if (input?.includes("image") !== true) {
    throw new PlanValidationError(
      "Use an image-capable model or continue with text feedback. The current model cannot receive image feedback.",
    );
  }
}

export function validatePlanDocument(plan: PlanRevision): void {
  validateInlinePlanText(plan.content);
  if (
    !plan.content.trim() ||
    plan.content ===
      "# Implementation plan\n\nDraft the recommended approach here.\n"
  ) {
    throw new PlanValidationError(
      "Write the implementation plan before requesting approval.",
    );
  }
}
