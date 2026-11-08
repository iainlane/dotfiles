#!/usr/bin/env node
import { main, logError } from "#cli/application/runtime";

try {
  await main(process.argv.slice(2));
} catch (error) {
  logError(error);

  process.exitCode = 1;
}
