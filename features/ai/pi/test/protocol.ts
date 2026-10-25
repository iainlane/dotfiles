import { Type } from "typebox";
import { Check } from "typebox/value";
import assert from "node:assert/strict";

const recordSchema = Type.Record(Type.String(), Type.Unknown());

export function isRecord(value: unknown): value is Record<string, unknown> {
  return Check(recordSchema, value);
}

function isCallable(value: unknown): value is (...args: unknown[]) => unknown {
  return typeof value === "function";
}

export function exportedFunction(
  module: unknown,
  key: string,
): (...args: unknown[]) => unknown {
  assert.ok(isRecord(module), "Expected a module export object");
  const value = module[key];
  assert.ok(isCallable(value), `Expected a callable ${key} export`);
  return value;
}

export function parseRecord(line: string): Record<string, unknown> {
  const value: unknown = JSON.parse(line);
  assert.ok(isRecord(value), "Expected a JSON object");
  return value;
}
