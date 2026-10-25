import { Type } from "typebox";
import { Check } from "typebox/value";
import { finite, record, text } from "./text.ts";

export interface Task {
  id: number;
  subject: string;
  status: "pending" | "in_progress" | "completed" | "deleted";
  activeForm: string | undefined;
  blockedBy: number[];
}

export interface TaskSummary {
  completed: number;
  total: number;
  running: number;
  blocked: number;
  current: string | undefined;
}

const nonnegativeNumber = Type.Number({ minimum: 0 });
const taskSchema = Type.Object({
  id: nonnegativeNumber,
  subject: Type.String(),
  status: Type.Union([
    Type.Literal("pending"),
    Type.Literal("in_progress"),
    Type.Literal("completed"),
    Type.Literal("deleted"),
  ]),
  activeForm: Type.Optional(Type.Unknown()),
  blockedBy: Type.Optional(Type.Unknown()),
});
const taskEntrySchema = Type.Object({
  type: Type.Literal("message"),
  message: Type.Object({
    role: Type.Literal("toolResult"),
    toolName: Type.Literal("todo"),
    details: Type.Object({
      tasks: Type.Array(Type.Unknown()),
      nextId: nonnegativeNumber,
    }),
  }),
});
const fleetSchema = Type.Object({
  fleet: Type.Object({
    version: Type.Literal(1),
    totalActive: nonnegativeNumber,
    omitted: Type.Optional(Type.Unknown()),
  }),
  asyncSnapshot: Type.Optional(Type.Unknown()),
});
const snapshotSchema = Type.Object({
  kind: Type.Literal("pi-subagents.async-status-snapshot"),
  version: Type.Literal(1),
  omitted: Type.Optional(Type.Unknown()),
  runs: Type.Optional(Type.Array(Type.Unknown())),
});
const runSchema = Type.Object({ label: Type.String(), state: Type.String() });

function readTask(raw: unknown): Task | undefined {
  if (!Check(taskSchema, raw)) {
    return undefined;
  }
  const status = raw.status;

  const blockedBy: number[] = [];

  if (Array.isArray(raw.blockedBy)) {
    for (const id of raw.blockedBy) {
      const parsed = finite(id);

      if (parsed !== undefined) {
        blockedBy.push(parsed);
      }
    }
  }

  return {
    id: raw.id,
    subject: text(raw.subject),
    status,
    activeForm: text(raw.activeForm) || undefined,
    blockedBy,
  };
}

export function readTasks(entries: readonly unknown[]): Task[] {
  let tasks: Task[] = [];

  for (const entry of entries) {
    if (!Check(taskEntrySchema, entry)) {
      continue;
    }
    const details = entry.message.details;

    const parsed = details.tasks.map(readTask);

    if (parsed.some((task) => task === undefined)) {
      continue;
    }

    tasks = parsed.filter((task): task is Task => task !== undefined);
  }

  return tasks;
}

export function taskSummary(tasks: readonly Task[]): TaskSummary {
  const visible = tasks.filter((task) => task.status !== "deleted");
  const active = visible.filter((task) => task.status === "in_progress");

  return {
    completed: visible.filter((task) => task.status === "completed").length,
    total: visible.length,
    running: active.length,
    blocked: visible.filter(
      (task) =>
        task.status !== "completed" &&
        task.blockedBy.some((id) => {
          const dependency = tasks.find((candidate) => candidate.id === id);

          return (
            !dependency ||
            (dependency.status !== "completed" &&
              dependency.status !== "deleted")
          );
        }),
    ).length,
    current: active[0]?.activeForm ?? active[0]?.subject,
  };
}

export interface AgentSummary {
  active: number;
  failed: number;
  paused: number;
  incomplete: boolean;
  runs: { label: string; state: string }[];
  stale: boolean;
}

export function readAgents(raw: unknown): AgentSummary | undefined {
  if (!Check(fleetSchema, raw)) {
    return undefined;
  }
  const active = raw.fleet.totalActive;
  const snapshot = Check(snapshotSchema, raw.asyncSnapshot)
    ? raw.asyncSnapshot
    : undefined;
  const valid = snapshot !== undefined;
  const omitted = record(snapshot?.omitted) ? snapshot.omitted : {};
  const runs: AgentSummary["runs"] = [];

  if (snapshot?.runs !== undefined) {
    for (const run of snapshot.runs) {
      if (Check(runSchema, run)) {
        runs.push({ label: text(run.label), state: text(run.state) });
      }
    }
  }

  return {
    active,
    failed: runs.filter(
      (run) =>
        run.state === "failed" ||
        run.state === "rejected" ||
        run.state === "partial",
    ).length,
    paused: runs.filter((run) => run.state === "paused").length,
    incomplete:
      !valid ||
      Number(raw.fleet.omitted ?? 0) > 0 ||
      Number(omitted.runs ?? 0) > 0 ||
      Number(omitted.children ?? 0) > 0 ||
      omitted.byteLimitExceeded === true,
    runs,
    stale: false,
  };
}
