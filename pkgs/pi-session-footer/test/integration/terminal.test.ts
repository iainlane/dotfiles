import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";
import { untilGone } from "#test/support/process-group.ts";
import { PiTerminal } from "#test/support/terminal.ts";

const cwd = fileURLToPath(new URL("../../", import.meta.url));
const fixture = fileURLToPath(
  new URL(import.meta.resolve("#test/fixtures/process.ts")),
);

function terminal(mode: string): PiTerminal {
  return new PiTerminal({
    command: [process.execPath, fixture, mode],
    cwd,
    env: { PATH: process.env.PATH ?? "", TERM: "xterm-256color" },
    columns: 80,
    rows: 24,
  });
}

function existingPids(ids: number[]): number[] {
  return ids.filter((pid) => {
    try {
      return process.kill(pid, 0);
    } catch (error) {
      if (!(error instanceof Error && "code" in error)) {
        throw error;
      }
      if (error.code === "ESRCH") {
        return false;
      }
      if (error.code === "EPERM") {
        return true;
      }
      throw error;
    }
  });
}

it("preserves real PTY dimensions, resize and Unicode input", async () => {
  const child = terminal("echo");
  await child.until((screen) =>
    expect(screen.join("\n")).toContain("ready:80x24"),
  );
  child.resize(91, 17);
  await child.until((screen) =>
    expect(screen.join("\n")).toContain("size:91x17"),
  );
  child.input("fixture 界é");
  await child.until((screen) =>
    expect(screen.join("\n")).toContain("input:fixture 界é"),
  );
});

it.each(["descendants-stubborn", "all-stubborn", "leader-exited"])(
  "closes a three-generation PTY process group: %s",
  async (mode) => {
    const child = terminal(mode);
    let ids: number[] = [];
    await child.until((screen) => {
      const matches = [
        ...screen.join("\n").matchAll(/process:(\d):(\d+)/g),
      ].toSorted((a, b) => Number(a[1]) - Number(b[1]));
      ids = matches.map((match) => Number(match[2]));
      expect(matches.map((match) => Number(match[1]))).toStrictEqual([0, 1, 2]);
    });
    if (mode === "leader-exited") {
      child.input("exit\r");
      await untilGone(() => existingPids(ids.slice(0, 1)).length > 0);
    }
    expect(existingPids(ids.slice(0, 1))).toStrictEqual(
      mode === "leader-exited" ? [] : ids.slice(0, 1),
    );
    await Promise.all([child.close(), child.close()]);
    expect(existingPids(ids)).toStrictEqual([]);
  },
);
