import { Type } from "typebox";

const positiveInteger = Type.Integer({
  minimum: 1,
  maximum: Number.MAX_SAFE_INTEGER,
});

export const chatGptCredentialSchema = Type.Object({
  type: Type.Literal("oauth"),
  access: Type.String({ minLength: 1 }),
  clientId: Type.String({ minLength: 1 }),
  expires: positiveInteger,
});

export const catalogueSchema = Type.Object({
  models: Type.Array(Type.Unknown()),
});

export const modelWindowSchema = Type.Object({
  slug: Type.String({ minLength: 1 }),
  context_window: positiveInteger,
});

export const cacheSchema = Type.Object({
  grant: Type.String(),
  refreshAfter: positiveInteger,
  contextWindows: Type.Record(Type.String({ minLength: 1 }), positiveInteger),
});

const openaiConfigSchema = Type.Object({
  baseUrl: Type.Optional(Type.String()),
  modelOverrides: Type.Optional(
    Type.Record(
      Type.String(),
      Type.Object({
        contextWindow: Type.Optional(Type.Number({ exclusiveMinimum: 0 })),
        maxTokens: Type.Optional(Type.Number({ exclusiveMinimum: 0 })),
      }),
    ),
  ),
  models: Type.Optional(Type.Array(Type.Object({ id: Type.String() }))),
});

export const modelConfigSchema = Type.Object({
  providers: Type.Object({
    openai: Type.Optional(openaiConfigSchema),
  }),
});
