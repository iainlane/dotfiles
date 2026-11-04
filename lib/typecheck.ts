// Runs `tsc` with this script's arguments and reports the diagnostics in the
// project's own files. TypeScript checks every `.ts` file that an import
// reaches, including the sources of dependencies that publish TypeScript, and
// has no option to skip them: `skipLibCheck` covers only declaration files.
import { spawn } from "node:child_process";
import { once } from "node:events";
import { resolve, sep } from "node:path";
import { createInterface } from "node:readline";
import type { Readable } from "node:stream";

// `--pretty false` prints `file(line,column): error TSnnnn: message`, or
// `error TSnnnn: message` for a diagnostic without a file, and indents the
// message's continuation lines.
const located = /^(.+)\(\d+,\d+\): (?:error|warning|message) TS\d+:/;

function fromDependency(file: string | undefined): boolean {
  return (
    file !== undefined && resolve(file).split(sep).includes("node_modules")
  );
}

const counts = { own: 0, ignored: 0 };

// Filters one output stream line by line, so the output's size does not
// matter. A continuation line belongs to the diagnostic before it.
async function filter(stream: Readable): Promise<void> {
  let started = false;
  let printing = false;
  const lines = createInterface({ input: stream, crlfDelay: Infinity });

  for await (const line of lines) {
    if (line === "") {
      continue;
    }

    if (started && /^\s/.test(line)) {
      if (printing) {
        process.stdout.write(`${line}\n`);
      }
      continue;
    }

    started = true;
    printing = !fromDependency(line.match(located)?.[1]);
    if (printing) {
      counts.own += 1;
      process.stdout.write(`${line}\n`);
    } else {
      counts.ignored += 1;
    }
  }
}

const child = spawn("tsc", ["--pretty", "false", ...process.argv.slice(2)], {
  stdio: ["ignore", "pipe", "pipe"],
});
const closed = once(child, "close");
await Promise.all([filter(child.stdout), filter(child.stderr)]);
const [status] = (await closed) as [number | null];

if (counts.ignored > 0) {
  const noun = counts.ignored === 1 ? "diagnostic" : "diagnostics";
  process.stderr.write(
    `Ignored ${counts.ignored} TypeScript ${noun} in dependencies.\n`,
  );
}

// A tsc that a signal stopped may not have printed every diagnostic.
if (status === null) {
  process.exitCode = 1;
} else if (counts.own > 0 || counts.ignored === 0) {
  process.exitCode = status;
}
