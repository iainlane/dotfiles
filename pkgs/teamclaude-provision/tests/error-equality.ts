import { expect } from "vitest";

// Vitest compares `cause` only when the expected error has one, and
// otherwise accepts any cause on the actual error.
function causeEquality(
  actual: unknown,
  expected: unknown,
): boolean | undefined {
  if (!(actual instanceof Error) || !(expected instanceof Error)) {
    return undefined;
  }

  if ((actual.cause === undefined) === (expected.cause === undefined)) {
    return undefined;
  }

  return false;
}

expect.addEqualityTesters([causeEquality]);
