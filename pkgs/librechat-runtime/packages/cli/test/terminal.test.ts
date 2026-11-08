import { PassThrough } from "node:stream";
import * as clack from "@clack/prompts";
import { afterEach, expect, it, vi } from "vitest";
import { CancelledError } from "#cli/application/errors";
import { TerminalPresentation } from "#cli/presentation/terminal";

vi.mock("@clack/prompts", { spy: true });

afterEach(() => vi.resetAllMocks());

it("uses plain stderr output without opening non-interactive prompts", async () => {
  const input = new PassThrough();
  const output = new PassThrough();
  const chunks: string[] = [];
  output.on("data", (chunk: Buffer) => chunks.push(chunk.toString("utf8")));
  const prompt = vi.mocked(clack.text);
  const presentation = new TerminalPresentation({
    input,
    output,
    interactive: false,
  });
  presentation.intro("Ignored heading");
  presentation.info("Account information");
  presentation.error("A safe error.");
  const result = await presentation.progress(
    "Ignored progress",
    async () => "done",
  );
  await expect(
    presentation.text({
      message: "Email",
      validate: (value: string) =>
        value.length === 0 ? "Required." : undefined,
    }),
  ).rejects.toThrow("Interactive input is unavailable.");
  expect({
    result,
    output: chunks.join(""),
    prompts: prompt.mock.calls,
  }).toStrictEqual({
    result: "done",
    output: "Account information\nError: A safe error.\n",
    prompts: [],
  });
});

it("sends interactive confirmation to stderr and defaults to No", async () => {
  const input = new PassThrough();
  const output = new PassThrough();
  const confirm = vi.mocked(clack.confirm).mockResolvedValue(false);
  const presentation = new TerminalPresentation({
    input,
    output,
    interactive: true,
  });
  expect({
    answer: await presentation.confirm("Delete?"),
    prompts: confirm.mock.calls,
  }).toStrictEqual({
    answer: false,
    prompts: [[{ message: "Delete?", initialValue: false, input, output }]],
  });
});

it("converts Clack cancellation into an application cancellation", async () => {
  vi.mocked(clack.password).mockResolvedValue(clack.CANCEL_SYMBOL);
  const presentation = new TerminalPresentation({
    input: new PassThrough(),
    output: new PassThrough(),
    interactive: true,
  });
  await expect(
    presentation.password({
      message: "Password",
      validate: (value: string) =>
        value.length === 0 ? "Required." : undefined,
    }),
  ).rejects.toThrow(CancelledError);
});
