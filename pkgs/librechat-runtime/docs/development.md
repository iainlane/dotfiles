# Development

From the repository root:

```sh
direnv exec . nix develop .#librechat-runtime
cd pkgs/librechat-runtime
pnpm prepare:code-bridge
pnpm install --frozen-lockfile
pnpm check
```

The shell supplies Node, pnpm, the pinned LibreChat package for native contract
tests and the compiled CodeAPI bridge. Preparation copies the bridge and its
generated declarations into `packages/codeapi-bridge/dist`.

## Packages

| Package          | Purpose                                                       |
| ---------------- | ------------------------------------------------------------- |
| `cli`            | Command-line entry points and presentation                    |
| `runtime`        | Account operations, host services and conversation workspaces |
| `codeapi-bridge` | Generated bridge to the pinned external CodeAPI               |

The CLI depends on the runtime; the runtime depends on the bridge. Each package
declares its production dependencies. Shared versions use the workspace's
`catalog`, and development tools are installed at the root.

## Checks

`pnpm build` compiles the runtime and CLI in dependency order. `pnpm typecheck`
checks source, tests and a consumer of the emitted declarations. `pnpm lint` and
`pnpm test` run Oxlint and Vitest. `pnpm check` runs all these commands.

Nix also checks the installed dependency links and runs the executable outside
the workspace:

```sh
direnv exec . nix build .#librechat-runtime
```

Run that command from the repository root. The [feature guide] describes the
startup and conversation VM checks.

[feature guide]: ../../../features/inference/librechat/README.md

## Imports and generated code

Package-local `#runtime/*` and `#cli/*` imports resolve through TypeScript paths
during development and Node package imports in the compiled output. Imports
between packages use explicit exports and `workspace:*` dependencies. The local
linter rejects parent-relative imports.

The bridge's JavaScript and declarations come from the same pinned TypeScript
sources in `pkgs/librechat-code`. Its preparation script copies the supplied
build output; it does not download sources or invoke Nix. Generated files and
compiler caches are not committed.

Nix deploys the CLI and its production dependencies with pnpm, then wraps the
compiled executable with Node.
