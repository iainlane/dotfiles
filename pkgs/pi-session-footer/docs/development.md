# Development

## Dependency shell

From the repository root:

```sh
nix develop .#pi-session-footer
cd pkgs/pi-session-footer
pnpm check
```

The shell supplies Node 24, pnpm 10.34.7, Git and the pinned Pi, Pretty and
Planning paths for native tests. It links the same patched development
dependencies as the Nix package. An existing regular `node_modules` directory
must be moved aside before entering the shell.

The dependency output is read-only. Change dependencies with
`pnpm add --lockfile-only <package>` or
`pnpm add --save-dev --lockfile-only <package>`, then refresh the Nix dependency
hash and re-enter the shell. Do not replace the patched dependency link with a
registry installation.

## Commands and test groups

| Command                 | Checks                                                   |
| ----------------------- | -------------------------------------------------------- |
| `pnpm typecheck`        | Strict source and test checking, without emitted files.  |
| `pnpm lint`             | Inherited type-aware Oxlint rules and the import policy. |
| `pnpm test:unit`        | Unit regressions under `test/unit`.                      |
| `pnpm test:integration` | Native Pi, PTY, provider and integration regressions.    |
| `pnpm test`             | Both test groups.                                        |
| `pnpm check`            | Typechecking, lint and both test groups.                 |

Integration files run sequentially for PTY isolation. Fixture preparation copies
selected third-party packages into ignored `.fixtures` directories and preserves
each package's dependency context. Owned fixture extensions are in
`test/fixtures`; shared test code is in `test/support`. Vitest writes its cache
to `.cache`, outside the read-only dependency tree.

The [demo guide] describes isolated native demonstrations and recordings.

[demo guide]: ../demo/README.md

## Modules and imports

Source directories separate application lifecycle, configuration and
persistence, domain readings, integration I/O, rendering and native UI. The
stable `index.ts` entry re-exports the extension; Pi loads its TypeScript source
directly.

Use the aliases in `package.json#imports` for cross-directory module imports.
TypeScript's `paths` must match those runtime mappings. Nearby `./` imports are
allowed. Parent-relative imports are forbidden in source, tests, scripts, demos
and configuration modules, including literal dynamic imports and CommonJS
imports. Filesystem paths and JSON configuration inheritance are separate from
module imports.

## Nix packaging and updates

From the repository root:

```sh
nix build .#pi-session-footer
nix run .#update-pi-session-footer
```

The shared local-package adapter selects existing purl identities and
`npmTarball` outputs. Native pnpm generates the patched graph during the
fixed-output fetch, then installs it offline with a frozen lock. Changes to
local dependency patches require new dependency hashes. The updater pins local
package versions, regenerates the portable pnpm lock and refreshes the hash for
each configured system.

Production uses native pnpm deployment with host peers excluded. Deployment does
not rerun the substitution hook because its generated lock already includes the
local resolutions. The installed package retains the portable manifest and
contains no test dependencies, fixtures or recording assets. Its installation
check verifies internal dependency links and loads the extension through native
Pi from an unrelated working directory.
