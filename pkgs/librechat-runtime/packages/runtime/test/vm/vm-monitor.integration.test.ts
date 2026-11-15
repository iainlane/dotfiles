import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { createInterface } from "node:readline";
import { join } from "node:path";
import { z } from "zod";
import { expect, it } from "vitest";
import { stopExistingVm } from "#runtime/vm/vm-monitor";

it("recovers through a real private UNIX monitor socket", async () => {
  const directory = await mkdtemp("/tmp/librechat-qmp-");

  const path = join(directory, "monitor");

  const vm = { mode: "negotiation", running: true };

  const server = createServer((socket) => {
    const lines = createInterface({ input: socket });

    socket.write(`${JSON.stringify({ QMP: {} })}\n`);

    lines.on("line", (line) => {
      const raw: unknown = JSON.parse(line);

      const command = z
        .object({ execute: z.string(), id: z.string() })
        .parse(raw);

      if (command.execute === "qmp_capabilities") {
        vm.mode = "command";
        socket.write(`${JSON.stringify({ return: {}, id: command.id })}\n`);

        return;
      }

      if (command.execute !== "quit" || vm.mode !== "command") {
        socket.write(
          `${JSON.stringify({ error: { class: "CommandNotFound" }, id: command.id })}\n`,
        );

        return;
      }

      vm.running = false;
      socket.end(`${JSON.stringify({ return: {}, id: command.id })}\n`);
    });
  });

  try {
    server.listen(path);

    await once(server, "listening");

    await stopExistingVm(path);

    expect(vm).toStrictEqual({ mode: "command", running: false });
  } finally {
    await new Promise<void>((resolve) => {
      server.close(() => resolve());
    });

    await rm(directory, { recursive: true, force: true });
  }
});
