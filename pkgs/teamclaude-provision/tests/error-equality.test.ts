import { expect, it } from "vitest";

it.each([
  {
    level: "the error",
    actual: new Error("failed", { cause: new Error("inner") }),
    expected: new Error("failed"),
  },
  {
    level: "its cause",
    actual: new Error("failed", {
      cause: new Error("inner", { cause: new Error("root") }),
    }),
    expected: new Error("failed", { cause: new Error("inner") }),
  },
])(
  "rejects a cause on $level that the expected error does not have",
  ({ actual, expected }) => {
    expect(actual).not.toStrictEqual(expected);
  },
);

it("matches errors with equal causes", () => {
  expect(new Error("failed", { cause: new Error("inner") })).toStrictEqual(
    new Error("failed", { cause: new Error("inner") }),
  );
});
