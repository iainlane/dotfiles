import { expect, it } from "vitest";
import { createStatusPublisher } from "../src/status.ts";

function bus() {
  const listeners = new Map<string, Set<(raw: unknown) => void>>();
  return {
    listeners,
    on(channel: string, callback: (raw: unknown) => void) {
      const callbacks = listeners.get(channel) ?? new Set();
      callbacks.add(callback);
      listeners.set(channel, callbacks);
      return () => {
        callbacks.delete(callback);
      };
    },
    emit(channel: string, raw: unknown) {
      for (const callback of listeners.get(channel) ?? []) {
        callback(raw);
      }
    },
  };
}
it("replays only the current session snapshot and clears publication on disposal", () => {
  const events = bus();
  const received: unknown[] = [];
  events.on("dotfiles:status:v1", (raw) => received.push(raw));
  const publisher = createStatusPublisher(events);
  publisher.publish({ sessionId: "one", active: true });
  expect(received).toStrictEqual([
    { version: 1, source: "planning", sessionId: "one", active: true },
  ]);
  for (const request of [
    null,
    {},
    { version: 2, sessionId: "one" },
    { version: 1, sessionId: "two" },
  ]) {
    events.emit("dotfiles:status:request:v1", request);
  }
  expect(received).toHaveLength(1);
  events.emit("dotfiles:status:request:v1", { version: 1, sessionId: "one" });
  expect(received).toHaveLength(2);
  publisher.publish({ sessionId: "two", active: false });
  events.emit("dotfiles:status:request:v1", { version: 1, sessionId: "one" });
  expect(received).toHaveLength(3);
  publisher.dispose();
  expect(received.at(-1)).toStrictEqual({
    version: 1,
    source: "planning",
    sessionId: "two",
    active: false,
  });
  events.emit("dotfiles:status:request:v1", { version: 1, sessionId: "two" });
  publisher.publish({ sessionId: "two", active: true });
  expect(received).toHaveLength(4);
  expect(events.listeners.get("dotfiles:status:request:v1")?.size).toBe(0);
});
