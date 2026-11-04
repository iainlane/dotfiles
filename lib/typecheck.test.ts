import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

const script =
  process.env.TYPECHECK_SCRIPT ??
  fileURLToPath(new URL("typecheck.ts", import.meta.url));
const shell = process.env.TYPECHECK_TEST_SHELL ?? "/bin/sh";

interface Run {
  status: number | null;
  stdout: string;
  stderr: string;
  arguments: string;
}

// Runs the script with a stub `tsc` that prints `output`, records its
// arguments, and exits with `status` or kills itself with SIGKILL.
function typecheck(output: string, status: number | "SIGKILL"): Run {
  const directory = mkdtempSync(join(tmpdir(), "typecheck-"));

  try {
    writeFileSync(join(directory, "output"), output);
    writeFileSync(
      join(directory, "tsc"),
      `#!${shell}\nprintf '%s\\n' "$*" >"${directory}/arguments"\ncat "${directory}/output"\n${status === "SIGKILL" ? "kill -KILL $$" : `exit ${status}`}\n`,
    );
    chmodSync(join(directory, "tsc"), 0o755);

    const result = spawnSync(process.execPath, [script, "--noEmit"], {
      encoding: "utf8",
      env: { ...process.env, PATH: `${directory}:${process.env.PATH ?? ""}` },
    });

    return {
      status: result.status,
      stdout: result.stdout,
      stderr: result.stderr,
      arguments: readFileSync(join(directory, "arguments"), "utf8"),
    };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

const dependency = [
  "node_modules/dep/src/index.ts(1,7): error TS6133: 'unused' is declared but its value is never read.",
  "../shared/node_modules/other/index.ts(4,1): error TS2322: Type 'number' is not assignable to type 'string'.",
  "  The expected type comes from this property.",
].join("\n");
const own = [
  "src/main.ts(2,7): error TS2322: Type 'number' is not assignable to type 'string'.",
  "  The expected type comes from this property.",
].join("\n");
const ignored = "Ignored 2 TypeScript diagnostics in dependencies.\n";

describe("typecheck", () => {
  for (const { name, output, status, expected } of [
    {
      name: "passes when every diagnostic is in a dependency",
      output: `${dependency}\n`,
      status: 2,
      expected: { status: 0, stdout: "", stderr: ignored },
    },
    {
      name: "reports only the project's own diagnostics",
      output: `${dependency}\n${own}\n`,
      status: 2,
      expected: { status: 2, stdout: `${own}\n`, stderr: ignored },
    },
    {
      name: "fails when tsc is killed after printing dependency diagnostics",
      output: `${dependency}\n`,
      status: "SIGKILL" as const,
      expected: { status: 1, stdout: "", stderr: ignored },
    },
    {
      name: "reads more output than the default child process buffer",
      output: `${dependency}\n`.repeat(6000),
      status: 2,
      expected: {
        status: 0,
        stdout: "",
        stderr: "Ignored 12000 TypeScript diagnostics in dependencies.\n",
      },
    },
    {
      name: "counts a single ignored diagnostic in the singular",
      output: `${dependency.split("\n")[0]}\n`,
      status: 2,
      expected: {
        status: 0,
        stdout: "",
        stderr: "Ignored 1 TypeScript diagnostic in dependencies.\n",
      },
    },
    {
      name: "reports a diagnostic without a file",
      output:
        "error TS5058: The specified path does not exist: 'tsconfig.json'.\n",
      status: 1,
      expected: {
        status: 1,
        stdout:
          "error TS5058: The specified path does not exist: 'tsconfig.json'.\n",
        stderr: "",
      },
    },
    {
      name: "reports a failure that produced no diagnostics",
      output: "panic: runtime error\n",
      status: 3,
      expected: { status: 3, stdout: "panic: runtime error\n", stderr: "" },
    },
    {
      name: "passes a clean run through",
      output: "",
      status: 0,
      expected: { status: 0, stdout: "", stderr: "" },
    },
  ]) {
    it(name, () => {
      assert.deepEqual(typecheck(output, status), {
        ...expected,
        arguments: "--pretty false --noEmit\n",
      });
    });
  }
});
