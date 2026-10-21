import type {
  PullRequestCiStatus,
  PullRequestSnapshot,
  PullRequestStateEvent,
} from "pi-prs/api";
import { finite, record, text } from "./text.ts";

function pullRequest(raw: unknown): PullRequestSnapshot | undefined {
  if (!record(raw) || !record(raw.target)) return undefined;

  const target = raw.target;
  const number = finite(target.number);
  const unresolvedThreadCount = finite(raw.unresolvedThreadCount);
  const lifecycle = raw.lifecycle;
  const mergeState = raw.mergeState;

  if (
    !number ||
    !Number.isSafeInteger(number) ||
    unresolvedThreadCount === undefined ||
    (lifecycle !== "open" &&
      lifecycle !== "merged" &&
      lifecycle !== "closed") ||
    (mergeState !== "mergeable" &&
      mergeState !== "blocked" &&
      mergeState !== "conflicting" &&
      mergeState !== "unknown")
  )
    return undefined;

  let ci: PullRequestCiStatus | undefined;

  if (raw.ci !== undefined) {
    if (
      !record(raw.ci) ||
      (raw.ci.state !== "running" &&
        raw.ci.state !== "failed" &&
        raw.ci.state !== "okay") ||
      finite(raw.ci.failedCount) === undefined
    )
      return undefined;

    ci = {
      state: raw.ci.state,
      url: typeof raw.ci.url === "string" ? raw.ci.url : "",
      failedCount: Number(raw.ci.failedCount),
    };
  }

  return {
    target: {
      host: text(target.host),
      owner: text(target.owner),
      name: text(target.name),
      number,
      url: typeof target.url === "string" ? target.url : "",
    },
    lifecycle,
    mergeState,
    headRefOid: text(raw.headRefOid),
    isDraft: raw.isDraft === true,
    autoMergeEnabled: raw.autoMergeEnabled === true,
    unresolvedThreadCount,
    watching: raw.watching === true,
    ci,
  };
}

export function readPr(raw: unknown): PullRequestStateEvent | undefined {
  if (
    !record(raw) ||
    raw.protocol !== 1 ||
    raw.source !== "pi-prs" ||
    typeof raw.repository !== "string" ||
    typeof raw.branch !== "string" ||
    (raw.health !== "ok" &&
      raw.health !== "unauthenticated" &&
      raw.health !== "error") ||
    finite(raw.updatedAt) === undefined
  )
    return undefined;

  const pr =
    raw.pullRequest === undefined ? undefined : pullRequest(raw.pullRequest);

  if (raw.pullRequest !== undefined && !pr) return undefined;

  return {
    protocol: 1,
    source: "pi-prs",
    repository: text(raw.repository),
    branch: text(raw.branch),
    health: raw.health,
    updatedAt: Number(raw.updatedAt),
    pullRequest: pr,
  };
}

export function readServiceTier(raw: unknown): string | undefined {
  if (!record(raw) || raw.protocol !== 1) return undefined;

  if (raw.type === "remove" && raw.id === "pi-service-tier.service-tier")
    return "";

  if (
    raw.type !== "upsert" ||
    !record(raw.widget) ||
    raw.widget.id !== "pi-service-tier.service-tier" ||
    !record(raw.widget.content)
  )
    return undefined;

  return typeof raw.widget.content.text === "string"
    ? text(raw.widget.content.text)
    : undefined;
}
