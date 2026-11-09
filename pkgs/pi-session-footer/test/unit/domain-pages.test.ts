import { expect, it, vi } from "vitest";
import { DomainPages } from "#footer/ui/inspection/domain-pages.ts";
import type {
  InspectionNavigation,
  InspectionPage,
  Section,
} from "#footer/ui/inspection/inspection-page.ts";
import { createSnapshot } from "#footer/domain/state.ts";

function fixture() {
  const state = createSnapshot(1000, "/work");
  const navigation: InspectionNavigation = {
    open: vi.fn<InspectionNavigation["open"]>(),
    section: vi.fn<InspectionNavigation["section"]>(),
    widget: vi.fn<InspectionNavigation["widget"]>(),
    sections: vi.fn<InspectionNavigation["sections"]>(),
    customise: vi.fn<InspectionNavigation["customise"]>(),
  };
  const pages = new DomainPages(() => state, navigation);
  const content = (section: Section) => {
    const page: InspectionPage = pages.page(section);
    if (page.kind !== "menu") {
      throw new Error("Expected a domain menu");
    }
    return page.content();
  };
  return { state, navigation, content };
}
it.each([
  ["quota", ["No quota data yet."]],
  ["workflow", ["No tasks recorded.", "Agents: No report yet"]],
  ["diagnostics", ["No findings received."]],
  ["git", ["No repository data yet."]],
] as const)(
  "shows a useful empty %s view without inferring health",
  (section, expected) => {
    const h = fixture();
    const content = h.content(section);
    expect({
      summary: content.summary,
      sections: content.rows.at(-1)?.value,
    }).toStrictEqual({
      summary: expected.map((value) => ({ value })),
      sections: "Sections…",
    });
  },
);
it("retains dependency and incomplete-report information behind selectable workflow rows", () => {
  const h = fixture();
  h.state.tasks = [
    {
      id: 1,
      subject: "Implement",
      status: "pending",
      activeForm: undefined,
      blockedBy: [2],
    },
  ];
  h.state.agents = {
    active: 2,
    failed: 0,
    paused: 0,
    stale: false,
    incomplete: true,
    runs: [],
  };
  const content = h.content("workflow");
  expect({
    summary: content.summary,
    tasks: content.rows
      .filter((row) => row.key.startsWith("task:"))
      .map(({ key, value, description }) => ({ key, value, description })),
  }).toStrictEqual({
    summary: [
      { value: "Tasks: 0 of 1 complete" },
      { value: "Blocked: 1 task" },
      { value: "Agents: 2 running · incomplete report", colour: "warning" },
    ],
    tasks: [
      { key: "task:1", value: "Implement", description: "Waiting on #2" },
    ],
  });
});
it("emphasises actual activity failures and GitHub conflicts and failed checks", () => {
  const h = fixture();
  h.state.activity.outcome = "failed";
  h.state.pr = {
    protocol: 1,
    source: "pi-prs",
    repository: "owner/project",
    branch: "main",
    health: "ok",
    updatedAt: 1000,
    pullRequest: {
      target: {
        host: "github.com",
        owner: "owner",
        name: "project",
        number: 42,
        url: "https://github.com/owner/project/pull/42",
      },
      lifecycle: "open",
      isDraft: false,
      autoMergeEnabled: false,
      mergeState: "conflicting",
      headRefOid: "abc",
      unresolvedThreadCount: 2,
      watching: false,
      ci: {
        state: "failed",
        failedCount: 1,
        url: "https://github.com/owner/project/actions",
      },
    },
  };
  expect({
    activity: h
      .content("overview")
      .summary.find((line) => line.value.startsWith("Activity:")),
    rows: h
      .content("git")
      .rows.filter((row) => ["pr", "checks", "reviews"].includes(row.key))
      .map(({ key, colour }) => ({ key, colour })),
  }).toStrictEqual({
    activity: { value: "Activity: failed", colour: "error" },
    rows: [
      { key: "pr", colour: "error" },
      { key: "checks", colour: "error" },
      { key: "reviews", colour: "warning" },
    ],
  });
});
it("shows real stale quota and diagnostic lower bounds without cleanliness caveats", () => {
  const h = fixture();
  h.state.now = 61_000;
  h.state.quota = {
    provider: "codex",
    windows: [
      { label: "Week", used: 32, resetAt: 121_000, windowSeconds: 604800 },
    ],
    lastSuccessAt: 1000,
    error: undefined,
    account: undefined,
    source: undefined,
  };
  h.state.diagnostics.receive({
    v: 1,
    cwd: h.state.cwd,
    seq: 1,
    files: [
      {
        path: "file.ts",
        truncated: true,
        diagnostics: [{ severity: "error", message: "Failure" }],
      },
    ],
  });
  expect({
    quota: h.content("quota").summary,
    diagnostics: h.content("diagnostics").summary,
  }).toStrictEqual({
    quota: [{ value: "Stale · updated 1m ago", colour: "warning" }],
    diagnostics: [{ value: "1+ errors · 0+ warnings", colour: "error" }],
  });
});
