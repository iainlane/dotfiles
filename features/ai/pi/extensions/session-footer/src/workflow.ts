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

function readTask(raw: unknown): Task | undefined {
  if (
    !record(raw) ||
    finite(raw.id) === undefined ||
    typeof raw.subject !== "string"
  ) {
    return undefined;
  }

  const status = raw.status;

  if (
    status !== "pending" &&
    status !== "in_progress" &&
    status !== "completed" &&
    status !== "deleted"
  ) {
    return undefined;
  }

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
    id: Number(raw.id),
    subject: text(raw.subject),
    status,
    activeForm: text(raw.activeForm) || undefined,
    blockedBy,
  };
}

export function readTasks(entries: readonly unknown[]): Task[] {
  let tasks: Task[] = [];

  for (const entry of entries) {
    if (!record(entry) || entry.type !== "message" || !record(entry.message)) {
      continue;
    }

    const message = entry.message;

    if (
      message.role !== "toolResult" ||
      message.toolName !== "todo" ||
      !record(message.details)
    ) {
      continue;
    }

    const details = message.details;

    if (!Array.isArray(details.tasks) || finite(details.nextId) === undefined) {
      continue;
    }

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
  if (!record(raw) || !record(raw.fleet) || raw.fleet.version !== 1) {
    return undefined;
  }

  const active = finite(raw.fleet.totalActive);

  if (active === undefined) {
    return undefined;
  }

  const snapshot = record(raw.asyncSnapshot) ? raw.asyncSnapshot : undefined;
  const valid =
    snapshot?.kind === "pi-subagents.async-status-snapshot" &&
    snapshot.version === 1;
  const omitted = valid && record(snapshot.omitted) ? snapshot.omitted : {};
  const runs: AgentSummary["runs"] = [];

  if (valid && Array.isArray(snapshot.runs)) {
    for (const run of snapshot.runs) {
      if (record(run)) {
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
