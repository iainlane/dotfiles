import { spawn } from "node:child_process";

export interface ProcessResult {
  status: number | null;
  stdout: string;
  stderr: string;
}

export async function runProcess(
  executable: string,
  args: string[],
  options: {
    signal: AbortSignal;
    env?: NodeJS.ProcessEnv;
    cwd?: string;
    input?: string;
  },
): Promise<ProcessResult> {
  const child = spawn(executable, args, {
    env: options.env,
    cwd: options.cwd,
    signal: options.signal,
  });
  const output = { stdout: "", stderr: "" };
  for (const stream of ["stdout", "stderr"] as const) {
    child[stream].setEncoding("utf8");
    child[stream].on("data", (chunk: string) => {
      output[stream] += chunk;
    });
  }
  const status = new Promise<number | null>((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code) => {
      resolve(code);
    });
  });
  child.stdin.end(options.input ?? "");
  return { status: await status, ...output };
}
