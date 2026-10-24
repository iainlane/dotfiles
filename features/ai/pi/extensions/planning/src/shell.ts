import { forEachChild, parse, type Command, type SyntaxNode } from "unbash";

export type ShellDecision =
  | { kind: "read-only" }
  | { kind: "mutation" | "unclassified"; reason: string };

const readers = new Set([
  "cat",
  "head",
  "tail",
  "wc",
  "ls",
  "pwd",
  "stat",
  "file",
  "du",
  "which",
  "type",
  "echo",
  "jq",
]);
const mutations = new Set([
  "rm",
  "mv",
  "cp",
  "touch",
  "mkdir",
  "rmdir",
  "install",
  "chmod",
  "chown",
  "tee",
  "truncate",
  "patch",
  "apply_patch",
]);
const gitReaders = new Set([
  "status",
  "diff",
  "log",
  "show",
  "ls-files",
  "ls-tree",
  "rev-parse",
  "grep",
  "describe",
]);
const gitMutations = new Set([
  "add",
  "commit",
  "reset",
  "checkout",
  "switch",
  "restore",
  "clean",
  "merge",
  "rebase",
  "push",
  "fetch",
  "pull",
  "cherry-pick",
  "apply",
  "am",
]);
const supportedNodes = new Set([
  "Script",
  "Statement",
  "Command",
  "Pipeline",
  "AndOr",
  "Word",
  "Literal",
  "SingleQuoted",
  "DoubleQuoted",
]);
const longOptions: Record<string, string> = {
  rg: "files files-with-matches files-without-match hidden no-ignore no-ignore-vcs glob iglob type type-not type-add follow regexp ignore-case case-sensitive smart-case line-number no-line-number heading no-heading max-count context before-context after-context count count-matches encoding crlf multiline no-messages with-filename no-filename column vimgrep json stats replace only-matching word-regexp fixed-strings sort sortr path-separator no-config text binary search-zip",
  grep: "regexp file ignore-case invert-match word-regexp line-regexp line-number count files-with-matches files-without-match recursive dereference-recursive include exclude exclude-dir extended-regexp fixed-strings perl-regexp text binary-files color colour context before-context after-context max-count only-matching with-filename no-filename null null-data",
  git: "short branch porcelain untracked-files ignored ignore-submodules stat numstat shortstat name-only name-status summary patch no-patch raw binary color no-color relative no-renames find-renames find-copies full-index abbrev no-abbrev unified word-diff word-diff-regex inter-hunk-context ignore-all-space ignore-space-change ignore-space-at-eol ignore-blank-lines cached staged no-ext-diff no-textconv no-index exit-code quiet oneline format pretty decorate no-decorate graph all tags remotes branches max-count since until author committer dategrep grep fixed-strings regexp-ignore-case extended-regexp perl-regexp first-parent no-merges merges reverse follow show-signature source full-name format quote-path literal-pathspecs glob-pathspecs icase-pathspecs show-toplevel show-prefix show-cdup git-dir git-common-dir absolute-git-dir is-inside-work-tree is-bare-repository verify symbolic symbolic-full-name abbrev-ref objects object-names count lines columns encoding date diff-filter pickaxe-all pickaxe-regex",
  sort: "reverse numeric-sort general-numeric-sort human-numeric-sort version-sort ignore-case dictionary-order ignore-leading-blanks ignore-nonprinting key field-separator stable unique check merge buffer-size parallel random-sort random-source zero-terminated",
  file: "mime mime-type mime-encoding brief separator print0 raw dereference special-files preserve-date magic-file files-from exclude exclude-quiet",
  cat: "show-all number number-nonblank squeeze-blank show-ends show-tabs show-nonprinting",
  head: "lines bytes quiet silent verbose zero-terminated",
  tail: "lines bytes quiet silent verbose zero-terminated",
  wc: "bytes chars lines words max-line-length files0-from",
  ls: "color all almost-all directory human-readable size format sort time time-style group-directories-first ignore hide indicator-style quoting-style classify escape recursive literal numeric-uid-gid",
  stat: "format printf file-system dereference terse",
  du: "apparent-size bytes block-size count-links dereference summarize total max-depth threshold exclude exclude-from files0-from",
  jq: "arg argjson slurpfile rawfile from-file library-path raw-input null-input slurp raw-output compact-output color-output monochrome-output join-output sort-keys tab indent exit-status stream seq unbuffered ascii-output",
};

function commandDecision(node: Command): ShellDecision {
  const name = node.name?.value;
  const args = node.args.map((arg) => (arg.type === "Word" ? arg.value : ""));

  if (name === undefined || name === "") {
    return { kind: "unclassified", reason: "No literal executable" };
  }
  if (mutations.has(name)) {
    return { kind: "mutation", reason: `${name} changes files` };
  }
  if (name === "git" && gitMutations.has(args[0] ?? "")) {
    return {
      kind: "mutation",
      reason: `git ${args[0]} changes repository state`,
    };
  }
  const reviewed = new Set([
    ...(name === "git" ? [] : ["help"]),
    "version",
    ...(longOptions[name]?.split(" ") ?? []),
  ]);
  if (
    args.some(
      (arg) =>
        arg.startsWith("--") &&
        arg !== "--" &&
        !reviewed.has(arg.slice(2).split("=")[0] ?? ""),
    )
  ) {
    return {
      kind: "unclassified",
      reason: "An unrecognised long option requires review",
    };
  }
  if (
    name === "file" &&
    args.some((arg) => /^-[^-]*C/.test(arg) || arg === "--compile")
  ) {
    return { kind: "mutation", reason: "file compiles a magic database" };
  }
  if (readers.has(name)) {
    return { kind: "read-only" };
  }

  if (name === "git") {
    if (args.some((arg) => arg.includes("%G") || arg === "--show-signature")) {
      return {
        kind: "unclassified",
        reason: "Git signature verification can invoke external helpers",
      };
    }
    const operation = args[0] ?? "";
    if (gitMutations.has(operation)) {
      return {
        kind: "mutation",
        reason: `git ${operation} changes repository state`,
      };
    }
    if (
      gitReaders.has(operation) &&
      !args.some(
        (arg) =>
          /^--(?:output|ext-diff|textconv|open-files-in-pager)(?:=|$)/.test(
            arg,
          ) ||
          (operation === "grep" && /^-[^-]*O/.test(arg)),
      )
    ) {
      return { kind: "read-only" };
    }
  }

  if (
    (name === "rg" || name === "grep") &&
    !args.some((arg) => /^--(?:pre|pre-glob|hostname-bin)(?:=|$)/.test(arg))
  ) {
    return { kind: "read-only" };
  }

  if (name === "sort") {
    if (
      args.some(
        (arg) =>
          arg === "-o" || /^--output(?:=|$)/.test(arg) || /^-[^-]*o/.test(arg),
      )
    ) {
      return { kind: "mutation", reason: "sort writes an output file" };
    }
    if (args.some((arg) => /^-[^-]*T/.test(arg))) {
      return {
        kind: "unclassified",
        reason: "sort can create temporary files at a requested path",
      };
    }
    if (args.some((arg) => /^--compress-program(?:=|$)/.test(arg))) {
      return {
        kind: "unclassified",
        reason: "sort invokes an external compressor",
      };
    }
    return { kind: "read-only" };
  }

  if (name === "sed") {
    if (args.some((arg) => /^-i|^--in-place/.test(arg))) {
      return { kind: "mutation", reason: "sed edits files in place" };
    }
    if (
      args[0] === "-n" &&
      /^\d+(?:,\d+)?p$/.test(args[1] ?? "") &&
      args.slice(2).every((arg) => !arg.startsWith("-"))
    ) {
      return { kind: "read-only" };
    }
  }

  if (name === "find") {
    if (
      args.some((arg) =>
        [
          "-delete",
          "-exec",
          "-execdir",
          "-ok",
          "-okdir",
          "-fprint",
          "-fprint0",
          "-fprintf",
        ].includes(arg),
      )
    ) {
      return {
        kind: "mutation",
        reason: "find executes commands or writes files",
      };
    }
    const options = new Set([
      "-H",
      "-L",
      "-P",
      "-type",
      "-name",
      "-iname",
      "-path",
      "-ipath",
      "-maxdepth",
      "-mindepth",
      "-print",
      "-print0",
      "-prune",
      "-o",
      "-a",
      "-not",
    ]);
    if (args.every((arg) => !arg.startsWith("-") || options.has(arg))) {
      return { kind: "read-only" };
    }
  }

  return { kind: "unclassified", reason: `No inspection rule for ${name}` };
}

export function classifyShell(source: string): ShellDecision {
  let decision: ShellDecision = { kind: "read-only" };
  let commands = 0;

  const reject = (next: ShellDecision) => {
    if (next.kind === "mutation" || decision.kind === "read-only") {
      decision = next;
    }
  };
  const visit = (node: SyntaxNode): void => {
    if (node.type === "Script" && (node.errors?.length ?? 0) > 0) {
      reject({
        kind: "unclassified",
        reason: "Shell syntax is incomplete or invalid",
      });
    }
    if (!supportedNodes.has(node.type)) {
      reject({
        kind: "unclassified",
        reason: "This shell construct requires review",
      });
    }
    if (node.type === "Statement" && node.background === true) {
      reject({
        kind: "unclassified",
        reason: "Background execution requires review",
      });
    }
    if (node.type === "Redirect") {
      reject({
        kind: node.operator.startsWith("<") ? "unclassified" : "mutation",
        reason: "Shell redirection requires review",
      });
    }
    if (node.type === "Command") {
      commands++;
      reject(commandDecision(node));
    }
    forEachChild(node, visit);
  };

  try {
    visit(parse(source));
  } catch {
    return { kind: "unclassified", reason: "Cannot parse shell command" };
  }

  return commands
    ? decision
    : { kind: "unclassified", reason: "No inspection command" };
}

export function inspectionCommand(source: string): string {
  if (classifyShell(source).kind !== "read-only") {
    throw new Error("Only recognised inspections can be normalised.");
  }
  const insertions: { position: number; text: string }[] = [];
  const visit = (node: SyntaxNode): void => {
    if (node.type === "Command" && node.name?.value === "git") {
      insertions.push({
        position: node.name.end,
        text: " --no-pager --no-optional-locks -c core.fsmonitor=false -c core.hooksPath=/dev/null -c log.showSignature=false -c gpg.program=false -c gpg.ssh.program=false -c gpg.x509.program=false",
      });
      const operation = node.args[0];
      if (
        operation?.type === "Word" &&
        ["diff", "show", "log"].includes(operation.value)
      ) {
        insertions.push({
          position: operation.end,
          text: " --no-ext-diff --no-textconv",
        });
      }
    }
    if (node.type === "Command" && node.name?.value === "rg") {
      insertions.push({ position: node.name.end, text: " --no-config" });
    }
    forEachChild(node, visit);
  };
  visit(parse(source));
  let command = source;
  for (const insertion of insertions.toSorted(
    (a, b) => b.position - a.position,
  )) {
    command =
      command.slice(0, insertion.position) +
      insertion.text +
      command.slice(insertion.position);
  }
  return command;
}
