import {
  configureSync,
  getLogger,
  resetSync,
  type Logger,
} from "@logtape/logtape";
import { diagnosticSink } from "@dotfiles/librechat-runtime/logging";
import { afterEach, vi } from "vitest";

afterEach(() => {
  resetSync();
  vi.useRealTimers();
});

export function testLogger(write: (text: string) => void): Logger {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(0);
  configureSync({
    reset: true,
    sinks: { output: diagnosticSink({ write }) },
    loggers: [
      { category: ["librechat"], lowestLevel: "debug", sinks: ["output"] },
      {
        category: ["logtape", "meta"],
        lowestLevel: "warning",
        sinks: ["output"],
      },
    ],
  });
  return getLogger(["librechat"]).with({ entryPoint: "runtime" });
}
