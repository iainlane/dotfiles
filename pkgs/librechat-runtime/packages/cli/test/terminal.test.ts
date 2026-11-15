import { PassThrough } from "node:stream";
import { stripVTControlCharacters } from "node:util";
import { expect, it } from "vitest";
import {
  CancelledError,
  InteractiveInputUnavailableError,
} from "#cli/application/errors";
import { TerminalPresentation } from "#cli/presentation/terminal";

function terminal(interactive: boolean) {
  const input = new PassThrough();
  const output = new PassThrough();
  const chunks: string[] = [];
  output.on("data", (chunk: Buffer) => chunks.push(chunk.toString("utf8")));
  const presentation = new TerminalPresentation({
    input,
    output,
    interactive,
  });
  return {
    presentation,
    type: (keys: string) => input.write(keys),
    screen: () => stripVTControlCharacters(chunks.join("")),
  };
}

it("uses plain stderr output without opening non-interactive prompts", async () => {
  const { presentation, screen } = terminal(false);
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
  ).rejects.toStrictEqual(new InteractiveInputUnavailableError());
  expect({ result, output: screen() }).toStrictEqual({
    result: "done",
    output: "Account information\nError: A safe error.\n",
  });
});

it("sends interactive confirmation to stderr and defaults to No", async () => {
  const { presentation, type, screen } = terminal(true);
  const answer = presentation.confirm("Delete?");
  type("\r");
  const output: unknown = expect.stringContaining("Delete?");
  expect({ answer: await answer, output: screen() }).toStrictEqual({
    answer: false,
    output,
  });
});

it("converts Clack cancellation into an application cancellation", async () => {
  const { presentation, type } = terminal(true);
  const password = presentation.password({
    message: "Password",
    validate: (value: string) => (value.length === 0 ? "Required." : undefined),
  });
  type("\u0003");
  await expect(password).rejects.toStrictEqual(new CancelledError());
});
