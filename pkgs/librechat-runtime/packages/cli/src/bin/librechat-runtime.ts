#!/usr/bin/env node
import { main } from "#cli/application/runtime";

await main(process.argv.slice(2));
