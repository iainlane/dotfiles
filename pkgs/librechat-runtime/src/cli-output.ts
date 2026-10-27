import type { Writable } from "node:stream";

async function flush(output: Writable): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    output.write("", (error: Error | null | undefined) => {
      if (error) {
        reject(error);

        return;
      }

      resolve();
    });
  });
}

export async function exitAfterFlushing(code: number): Promise<never> {
  const results = await Promise.allSettled([
    flush(process.stdout),
    flush(process.stderr),
  ]);

  process.exit(
    results.some((result) => result.status === "rejected") ? 1 : code,
  );
}
