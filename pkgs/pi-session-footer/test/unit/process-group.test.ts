import { expect, it, onTestFinished, vi } from "vitest";
import { ProcessGroup } from "#test/support/process-group.ts";

it("keeps waiting when an existence probe reports permission denied", async () => {
  let polls = 0;
  const kill = vi.spyOn(process, "kill").mockImplementation((_pid, signal) => {
    if (signal === 0) {
      polls++;
      throw Object.assign(new Error("probe"), {
        code: polls === 1 ? "EPERM" : "ESRCH",
      });
    }
    return true;
  });
  onTestFinished(() => kill.mockRestore());
  await new ProcessGroup(12345).close();
  expect(kill.mock.calls).toStrictEqual([
    [-12345, "SIGTERM"],
    [-12345, 0],
    [-12345, 0],
  ]);
});

it("does not ignore permission errors when signalling the group", async () => {
  const error = Object.assign(new Error("denied"), { code: "EPERM" });
  const kill = vi.spyOn(process, "kill").mockImplementation(() => {
    throw error;
  });
  onTestFinished(() => kill.mockRestore());
  await expect(new ProcessGroup(12345).close()).rejects.toBe(error);
  expect(kill.mock.calls).toStrictEqual([[-12345, "SIGTERM"]]);
});
