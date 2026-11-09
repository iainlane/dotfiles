# Development

## Dependency shell

From the repository root, build the native packages that the integration tests
use, then run the checks in the package's development shell:

```sh
pi=$(nix build .#pi --no-link --print-out-paths)
pretty=$(nix build .#pi-pretty --no-link --print-out-paths)
planning=$(nix build .#pi-planning --no-link --print-out-paths)
cd pkgs/pi-session-footer
nix develop ../..#pi-session-footer.devShell --command env \
  PI_TEST_HOST="$pi/bin/pi" \
  PI_TEST_PRETTY="$pretty/lib/node_modules/@heyhuynhgiabuu/pi-pretty" \
  PI_TEST_PLANNING="$planning/lib/node_modules/@dotfiles/pi-planning" \
  pnpm check
```

Entering the shell links the Nix build's `node_modules` into the working tree.
It contains the repository's local builds of patched dependencies and a
`node-pty` compiled from source. The linked dependencies are read-only, so
change dependencies with `pnpm add --lockfile-only <package>` or
`pnpm add --save-dev --lockfile-only <package>`, run the updater, and enter the
shell again.

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

The build uses the repository's shared TypeScript package helper. Nix fetches
the dependencies in `pnpm-lock.yaml` into a pnpm store and installs them offline
with a frozen lockfile. It then replaces each dependency that the repository
also builds, such as the patched `@juicesharp/rpiv-btw`, with the local build.
The dependency hash covers only the registry packages, so a change to a local
package does not change it.

pnpm resolves a dependency's own dependencies from its registry manifest. When a
local build declares different dependencies, the updater records the difference
as a `packageExtensions` entry in `pnpm-workspace.yaml`, and the lockfile
installs what the local build needs. The updater also pins local package
versions, regenerates the lockfile and refreshes the dependency hash. The build
fails with a request to run the updater when the lockfile no longer matches the
local packages.

`pnpm-workspace.yaml` allows only `node-pty` to run its build script, and the
Nix build compiles it from source with node-gyp. The installed package contains
the files that `pnpm pack` publishes and the production dependencies, without
host peers, test dependencies, fixtures or recording assets.
