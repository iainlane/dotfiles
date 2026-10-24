import { expect, it } from "vitest";
import { classifyShell, inspectionCommand } from "../src/shell.ts";

it.each([
  "rg --files | sort | head -20",
  "git status --short && git diff --stat",
  "sed -n '20,40p' src/file.ts",
  "cat README.md | wc -l",
  "find src -type f -name '*.ts'",
])("recognises an inspection: %s", (command) => {
  expect(classifyShell(command)).toStrictEqual({ kind: "read-only" });
});

it.each([
  "rm file",
  "cat README.md > file",
  "git reset --hard",
  "find . -delete",
  "find . -exec rm {} \\;",
  "sed -i 's/a/b/' file",
  "sort -o file file",
])("blocks an explicit mutation: %s", (command) => {
  expect(classifyShell(command).kind).toBe("mutation");
});

it.each([
  "git status --help",
  "git ls-files --help",
  "git log --show-signature -1",
  "git log --format='%G?' -1",
  "python3 inspect.py",
  "LD_PRELOAD=./hook.so cat README.md",
  "GIT_EXTERNAL_DIFF=./hook git diff",
  "RIPGREP_CONFIG_PATH=./config rg pattern",
  "cat $(touch file)",
  "rg --pre=script pattern",
  "git -c alias.inspect='!touch file' inspect",
  "sed '1e touch file' file",
  "cat <(touch file)",
  "git diff --output=file",
  "cat README.md &",
  "function inspect() { touch file; }; inspect",
  "cat '",
  "sort --compress-program=script file",
  "git grep --open-files-in-pager=script pattern",
  "file -C -m ./magic",
  "file --compile -m ./magic",
  "sed -n 1p --expression='w victim' file",
  "sed -n 1p -f ./program file",
  "[[ 'a[$(touch arithmetic-marker)]' -eq 0 ]]; cat file",
  "printf -v 'a[$(touch printf-marker)]' '%s' x; cat file",
  "sort --out=sort-output input",
  "sort --compress-prog=script input",
  "file --compi -m magic",
  "git diff --out=output",
  "rg --pr=script pattern",
  "sort -T. input",
  "sort --temporary-directory=. input",
  "sort -- --out=literal-file",
])("requires an explicit decision: %s", (command) => {
  expect(classifyShell(command).kind).not.toBe("read-only");
});

it("disables Git helpers, pagers and index refresh writes in inspections", () => {
  expect(inspectionCommand("git status --short && git diff -- file.ts")).toBe(
    "git --no-pager --no-optional-locks -c core.fsmonitor=false -c core.hooksPath=/dev/null -c log.showSignature=false -c gpg.program=false -c gpg.ssh.program=false -c gpg.x509.program=false status --short && git --no-pager --no-optional-locks -c core.fsmonitor=false -c core.hooksPath=/dev/null -c log.showSignature=false -c gpg.program=false -c gpg.ssh.program=false -c gpg.x509.program=false diff --no-ext-diff --no-textconv -- file.ts",
  );
});
