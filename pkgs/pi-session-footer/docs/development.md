# Development

## Development shell

Allow this directory's `.envrc` with direnv, then install and check:

```sh
pnpm install
pnpm check
```

The shell supplies Node, the pinned pnpm, Git and the Pi, Pretty and Planning
paths for native tests. It links the tarballs of this repository's npm packages
into `.nix-providers`. The overrides in `pnpm-workspace.yaml` install those
tarballs in place of the registry releases, and pnpm otherwise works as usual.

The lockfile records each tarball's integrity. After changing dependencies, or
when one of the local packages changes, run `nix run .#update-pi-session-footer`
from the repository root. It refreshes the overrides, the lockfile and the Nix
dependency hashes.

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
to `.cache`.

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

The build links the local packages' tarballs as the development shell does and
installs offline with the frozen lockfile. When a local package changes, its
tarball no longer matches the recorded integrity, and the build fails until the
updater has refreshed the lockfile.

The installed package consists of the files in its own npm tarball and a
production install of its dependencies, with host peers excluded. It contains no
test dependencies, fixtures or recording assets. Its installation check verifies
internal dependency links and loads the extension through native Pi from an
unrelated working directory.
