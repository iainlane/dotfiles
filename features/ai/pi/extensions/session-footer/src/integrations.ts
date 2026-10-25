import { Type, type Static } from "typebox";
import { Check } from "typebox/value";
import { isPullRequestStateEvent } from "pi-prs/api";
import type { PullRequestSnapshot, PullRequestStateEvent } from "pi-prs/api";
import { text } from "./text.ts";

const countSchema = Type.Integer({
  minimum: 0,
  maximum: Number.MAX_SAFE_INTEGER,
});
const pullRequestSchema = Type.Object({
  target: Type.Object({
    number: Type.Integer({ minimum: 1, maximum: Number.MAX_SAFE_INTEGER }),
    host: Type.Optional(Type.String()),
    owner: Type.Optional(Type.String()),
    name: Type.Optional(Type.String()),
    url: Type.Optional(Type.String()),
  }),
  lifecycle: Type.Union([
    Type.Literal("open"),
    Type.Literal("merged"),
    Type.Literal("closed"),
  ]),
  mergeState: Type.Union([
    Type.Literal("mergeable"),
    Type.Literal("blocked"),
    Type.Literal("conflicting"),
    Type.Literal("unknown"),
  ]),
  unresolvedThreadCount: countSchema,
  headRefOid: Type.Optional(Type.String()),
  isDraft: Type.Optional(Type.Boolean()),
  autoMergeEnabled: Type.Optional(Type.Boolean()),
  watching: Type.Optional(Type.Boolean()),
  ci: Type.Optional(
    Type.Object({
      state: Type.Union([
        Type.Literal("running"),
        Type.Literal("failed"),
        Type.Literal("okay"),
      ]),
      failedCount: countSchema,
      url: Type.Optional(Type.String()),
    }),
  ),
});
const prStateSchema = Type.Object({
  protocol: Type.Literal(1),
  source: Type.Literal("pi-prs"),
  repository: Type.String(),
  branch: Type.String(),
  health: Type.Union([
    Type.Literal("ok"),
    Type.Literal("unauthenticated"),
    Type.Literal("error"),
  ]),
  updatedAt: Type.Number({ minimum: 0 }),
  pullRequest: Type.Optional(pullRequestSchema),
});

function pullRequest(
  raw: Static<typeof pullRequestSchema>,
): PullRequestSnapshot {
  return {
    target: {
      host: text(raw.target.host),
      owner: text(raw.target.owner),
      name: text(raw.target.name),
      number: raw.target.number,
      url: raw.target.url ?? "",
    },
    lifecycle: raw.lifecycle,
    mergeState: raw.mergeState,
    headRefOid: text(raw.headRefOid),
    isDraft: raw.isDraft === true,
    autoMergeEnabled: raw.autoMergeEnabled === true,
    unresolvedThreadCount: raw.unresolvedThreadCount,
    watching: raw.watching === true,
    ci: raw.ci === undefined ? undefined : { ...raw.ci, url: raw.ci.url ?? "" },
  };
}

export function readPr(raw: unknown): PullRequestStateEvent | undefined {
  if (!isPullRequestStateEvent(raw) || !Check(prStateSchema, raw)) {
    return undefined;
  }
  return {
    protocol: 1,
    source: "pi-prs",
    repository: text(raw.repository),
    branch: text(raw.branch),
    health: raw.health,
    updatedAt: raw.updatedAt,
    pullRequest:
      raw.pullRequest === undefined ? undefined : pullRequest(raw.pullRequest),
  };
}

const serviceTierSchema = Type.Union([
  Type.Object({
    protocol: Type.Literal(1),
    type: Type.Literal("remove"),
    id: Type.Literal("pi-service-tier.service-tier"),
  }),
  Type.Object({
    protocol: Type.Literal(1),
    type: Type.Literal("upsert"),
    widget: Type.Object({
      id: Type.Literal("pi-service-tier.service-tier"),
      content: Type.Object({ text: Type.String() }),
    }),
  }),
]);

export function readServiceTier(raw: unknown): string | undefined {
  if (!Check(serviceTierSchema, raw)) {
    return undefined;
  }
  return raw.type === "remove" ? "" : text(raw.widget.content.text);
}
