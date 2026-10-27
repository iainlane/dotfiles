import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { createInterface } from "node:readline";
import { join } from "node:path";
import { z } from "zod";
import { expect, it } from "vitest";
import { stopExistingVm } from "../src/vm-monitor.ts";

it("recovers through a real private UNIX monitor socket", async () => {
  const directory = await mkdtemp("/tmp/librechat-qmp-");

  const path = join(directory, "monitor");

  const commands: unknown[] = [];

  const server = createServer((socket) => {
    const lines = createInterface({ input: socket });

    socket.write(`${JSON.stringify({ QMP: {} })}\n`);

    lines.on("line", (line) => {
      const raw: unknown = JSON.parse(line);

      const command = z
        .object({ execute: z.string(), id: z.string() })
        .parse(raw);

      commands.push(command);

      const response = `${JSON.stringify({ return: {}, id: command.id })}\n`;

      if (command.execute === "quit") {
        socket.end(response);

        return;
      }

      socket.write(response);
    });
  });

  try {
    server.listen(path);

    await once(server, "listening");

    await stopExistingVm(path);

    expect(commands).toStrictEqual([
      { execute: "qmp_capabilities", id: "capabilities" },
      { execute: "quit", id: "quit" },
    ]);
  } finally {
    await new Promise<void>((resolve) => {
      server.close(() => resolve());
    });

    await rm(directory, { recursive: true, force: true });
  }
});
