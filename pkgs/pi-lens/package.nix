# To update: nix run .#update-pi-lens
{
  callPackage,
  jq,
  pkgsCross,
}: let
  luaGrammar = pkgsCross.wasi32.tree-sitter-grammars.tree-sitter-lua;
in
  (callPackage ../build-support/pi-extension.nix {
    npmName = "pi-lens";
    source = ./source.json;
    npmRoot = ./npm-deps;

    # The registry tarball includes dist/ and the core grammars. Building from
    # the release tag would run prepare, which requires network access.

    # pi-lens imports TypeScript at runtime but declares it as a dev dependency.
    # The shared builder omits dev dependencies.
    npmDependencies.typescript = "7.0.2";

    # ast-grep distributes its native addon through optional dependencies.
    omitOptional = false;

    description = "Real-time code feedback for pi through LSP, linters, formatters, type checking and structural analysis";
  }).overrideAttrs (previous: {
    # pi-lens downloads Lua on demand into its package directory, which is
    # read-only in the Nix store. Its runtime hash check must use the Nix-built
    # grammar's hash, not the hash of the npm binary.
    postInstall =
      (previous.postInstall or "")
      + ''
        package="$out/${previous.passthru.packageRoot}"
        install -m644 ${luaGrammar}/parser.wasm "$package/grammars/tree-sitter-lua.wasm"
        hash="$(sha256sum "$package/grammars/tree-sitter-lua.wasm")"

        ${jq}/bin/jq --arg hash "sha256:''${hash%% *}" --arg version ${luaGrammar.version} '
          .grammars["tree-sitter-lua.wasm"] = $hash
          | .overrides["tree-sitter-lua.wasm"] = {
              package: "nixpkgs/tree-sitter-lua",
              version: $version
            }
        ' "$package/scripts/grammars.lock.json" > "$package/scripts/grammars.lock.json.new"
        mv "$package/scripts/grammars.lock.json.new" "$package/scripts/grammars.lock.json"

        ${jq}/bin/jq '{
          npmPackage: .overrides["tree-sitter-lua.wasm"].package,
          version: .overrides["tree-sitter-lua.wasm"].version,
          sha256: .grammars["tree-sitter-lua.wasm"]
        }' "$package/scripts/grammars.lock.json" > "$package/grammars/tree-sitter-lua.wasm.json"
      '';
  })
