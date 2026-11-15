import { spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { setTimeout } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { expect, it, onTestFinished } from "vitest";
import { ProcessGroup, type Kill } from "#test/support/process-group.ts";

const fixture = fileURLToPath(
  new URL(import.meta.resolve("#test/fixtures/process.ts")),
);

interface Members {
  own: number;
  foreign: number;
}

// kill(2) on a group succeeds if the caller may signal at least one member,
// and fails with EPERM if members exist but the caller may signal none of them.
class FakeProcessGroup {
  readonly id: number;
  readonly members: Members;

  constructor(id: number, members: Members) {
    this.id = id;
    this.members = members;
  }

  readonly kill: Kill = (pid, signal) => {
    if (pid !== -this.id || this.members.own + this.members.foreign === 0) {
      throw errno("ESRCH");
    }
    if (this.members.own === 0) {
      throw errno("EPERM");
    }
    if (signal === "SIGKILL") {
      this.members.own = 0;
    }
    return true;
  };
}

function errno(code: string): Error {
  return Object.assign(new Error(code), { code });
}

function alive(pid: number): boolean {
  try {
    return process.kill(pid, 0);
  } catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ESRCH") {
      return false;
    }
    throw error;
  }
}

interface StartedGroup {
  leader: ChildProcess;
  pid: number;
  pids: number[];
}

async function startGroup(mode: string): Promise<StartedGroup> {
  const leader = spawn(process.execPath, [fixture, mode], {
    detached: true,
    stdio: ["pipe", "pipe", "inherit"],
  });
  await once(leader, "spawn");
  const { pid, stdout } = leader;
  if (pid === undefined || stdout === null) {
    throw new Error(`Cannot start ${fixture}`);
  }

  onTestFinished(() => {
    if (alive(-pid)) {
      process.kill(-pid, "SIGKILL");
    }
  });

  const generations = new Map<number, number>();
  for await (const line of createInterface({ input: stdout })) {
    const match = /^process:(\d):(\d+)$/.exec(line);
    if (match !== null) {
      generations.set(Number(match[1]), Number(match[2]));
    }
    if (generations.size === 3) {
      break;
    }
  }

  const pids = [...generations]
    .toSorted(([a], [b]) => a - b)
    .map(([, child]) => child);
  return { leader, pid, pids };
}

it.each(["descendants-stubborn", "all-stubborn", "leader-exited"])(
  "kills every process in a three-generation group: %s",
  async (mode) => {
    const { leader, pid, pids } = await startGroup(mode);
    const started = pids.map((child) => alive(child));

    if (mode === "leader-exited") {
      leader.stdin?.end("exit\n");
      await once(leader, "exit");
    }

    await new ProcessGroup(pid).close();
    expect({
      started,
      group: alive(-pid),
      processes: pids.map((child) => alive(child)),
    }).toStrictEqual({
      started: [true, true, true],
      group: false,
      processes: [false, false, false],
    });
  },
);

it("waits while the group contains only processes it cannot signal", async () => {
  const group = new FakeProcessGroup(12345, { own: 2, foreign: 1 });
  const closing = new ProcessGroup(12345, group.kill).close();
  expect({
    settled: await Promise.race([closing, setTimeout(200, "pending")]),
    members: group.members,
  }).toStrictEqual({ settled: "pending", members: { own: 0, foreign: 1 } });

  group.members.foreign = 0;
  await expect(closing).resolves.toBeUndefined();
});

it("rejects when it cannot signal any process in the group", async () => {
  const group = new FakeProcessGroup(12345, { own: 0, foreign: 2 });
  await expect(
    new ProcessGroup(12345, group.kill).close(),
  ).rejects.toStrictEqual(errno("EPERM"));
});
