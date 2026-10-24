# To update: nix run .#update-pi-lens
{
  autoPatchelfHook,
  callPackage,
  fetchurl,
  jq,
  lib,
  nodejs,
  pkgsCross,
  stdenv,
}: let
  luaGrammar = pkgsCross.wasi32.tree-sitter-grammars.tree-sitter-lua;
  grammarLock = lib.importJSON ./grammars.lock.json;
  grammars = lib.mapAttrs (filename: digest: let
    override = grammarLock.overrides.${filename} or {};
  in {
    package = override.package or grammarLock.package;
    version = override.version or grammarLock.version;
    hash = digest;
    source = fetchurl {
      url = override.url or "https://unpkg.com/${grammarLock.package}@${grammarLock.version}/out/${filename}";
      sha256 = lib.removePrefix "sha256:" digest;
    };
  }) (removeAttrs grammarLock.grammars ["tree-sitter-lua.wasm"]);
in
  (callPackage ../build-support/pi-extension.nix {
    npmName = "pi-lens";
    source = ./source.json;
    npmRoot = ./npm-deps;

    # The registry tarball includes dist/ and the core grammars. Building from
    # the release tag would run prepare, which requires network access.

    metadataFiles."grammars.lock.json" = "scripts/grammars.lock.json";

    # ast-grep distributes its native addon through optional dependencies.
    omitOptional = false;

    description = "Real-time code feedback for pi through LSP, linters, formatters, type checking and structural analysis";
  }).overrideAttrs (previous: {
    nativeBuildInputs = (previous.nativeBuildInputs or []) ++ lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
    buildInputs = (previous.buildInputs or []) ++ lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];
    nativeInstallCheckInputs = [nodejs];
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      node "$out/${previous.passthru.packageRoot}/scripts/install-selftest.mjs"
      node --experimental-strip-types ${./install-check.mts} "$out/${previous.passthru.packageRoot}"
      runHook postInstallCheck
    '';

    # pi-lens downloads Lua on demand into its package directory, which is
    # read-only in the Nix store. Its runtime hash check must use the Nix-built
    # grammar's hash, not the hash of the npm binary.
    postInstall =
      (previous.postInstall or "")
      + ''
        package="$out/${previous.passthru.packageRoot}"
        cmp "$package/scripts/grammars.lock.json" ${./grammars.lock.json}
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (filename: grammar: ''
            install -m644 ${grammar.source} "$package/grammars/${filename}"
            ${jq}/bin/jq -n \
              --arg npmPackage ${lib.escapeShellArg grammar.package} \
              --arg version ${lib.escapeShellArg grammar.version} \
              --arg sha256 ${lib.escapeShellArg grammar.hash} \
              '{npmPackage: $npmPackage, version: $version, sha256: $sha256}' \
              > "$package/grammars/${filename}.json"
          '')
          grammars)}
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
