import { Type, type Static } from "typebox";
import { maxFeedbackCodeUnits, maxPlanCodeUnits } from "./validation.ts";

export const emptyPlanInputSchema = Type.Object(
  {},
  { additionalProperties: false },
);

export const planRevisionSchema = Type.Object(
  {
    path: Type.String(),
    revision: Type.String(),
    content: Type.String(),
  },
  { additionalProperties: false },
);

export const enterPlanOutputSchema = Type.Union([
  Type.Object(
    {
      status: Type.Literal("active"),
      path: Type.String(),
      instructions: Type.String(),
    },
    { additionalProperties: false },
  ),
  Type.Object(
    { status: Type.Literal("declined"), instructions: Type.String() },
    { additionalProperties: false },
  ),
]);

export const submitPlanOutputSchema = Type.Object(
  {
    version: Type.Literal(1),
    decision: Type.Union([
      Type.Literal("current"),
      Type.Literal("clear"),
      Type.Literal("revise"),
      Type.Literal("cancel"),
    ]),
    plan: Type.Object(
      {
        path: Type.String(),
        revision: Type.String(),
        content: Type.String({ maxLength: maxPlanCodeUnits }),
      },
      { additionalProperties: false },
    ),
    imageCount: Type.Integer({ minimum: 0 }),
    feedback: Type.Optional(Type.String({ maxLength: maxFeedbackCodeUnits })),
  },
  { additionalProperties: false },
);

export type EnterPlanOutput = Static<typeof enterPlanOutputSchema>;
export type SubmitPlanOutput = Static<typeof submitPlanOutputSchema>;
