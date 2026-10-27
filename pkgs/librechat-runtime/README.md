# LibreChat runtime

This private Node.js 24 ESM package manages the native LibreChat services,
conversation workspaces and CodeAPI integration. Production TypeScript is in
`src/`; unit, integration and provider contract tests are in `test/`.

The Nix package runs TypeScript directly with Node's type stripping. It installs
production sources and dependencies, and adds the bundled CodeAPI bridge beside
its declaration file. The LibreChat bootstrap adapter loads CommonJS modules
relative to the installed LibreChat package and validates their exports at
runtime.

From the repository root, enter the package's development environment:

```sh
direnv exec . nix develop .#librechat-runtime
cd pkgs/librechat-runtime
npm ci --ignore-scripts --offline --no-audit --no-fund
npm run check
```

`npm run check` runs the compiler, type-aware lint and Vitest. The development
environment supplies `LIBRECHAT_TEST_ROOT`, so the contract tests use the pinned
LibreChat configuration schema, model loader and validator. The tests use
fixture credentials and make no external provider calls.

The `librechat-startup` flake check additionally starts the generated service,
bootstraps an administrator and a personal agent with a whole-server MCP
selection, checks bootstrap idempotence and streamed output, and exercises
nonblocking authentication with loopback model, OAuth and MCP fixtures. It logs
in, restarts the service and logs in again. Darwin runs in the Nix sandbox;
Linux runs inside a NixOS VM. That check isolates external providers, MCPs,
skills, retrieval, workspace hooks and conversation VM execution.
