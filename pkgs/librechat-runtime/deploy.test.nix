{
  lib,
  nix,
  nodejs_24,
  pnpm,
  runCommandLocal,
}: let
  files = {
    "package.json" = builtins.toJSON {
      name = "deployment-fixture";
      private = true;
      devDependencies.fixture-dev = "file:dev-only";
    };
    "dev-only/package.json" = builtins.toJSON {
      name = "fixture-dev";
      version = "1.0.0";
      main = "index.js";
    };
    "dev-only/index.js" = ''
      throw new Error("A development dependency was installed.");
    '';
    "external-prod/package.json" = builtins.toJSON {
      name = "fixture-prod";
      version = "1.0.0";
      type = "module";
      exports = "./index.js";
    };
    "external-prod/index.js" = ''
      export const external = "production dependency";
    '';
    "pnpm-workspace.yaml" = ''
      packages:
        - packages/*
      injectWorkspacePackages: true
      managePackageManagerVersions: false
    '';
    "packages/cli/package.json" = builtins.toJSON {
      name = "@dotfiles/librechat-cli";
      version = "0.1.0";
      type = "module";
      files = ["dist"];
      dependencies = {
        "@dotfiles/librechat-runtime" = "workspace:*";
        fixture-prod = "file:../../external-prod";
      };
    };
    "packages/cli/dist/index.js" = ''
      import { value } from "@dotfiles/librechat-runtime";
      import { external } from "fixture-prod";
      console.log(JSON.stringify({ value, external }));
    '';
    "packages/runtime/package.json" = builtins.toJSON {
      name = "@dotfiles/librechat-runtime";
      version = "0.1.0";
      type = "module";
      exports = "./dist/index.js";
      files = ["dist"];
      dependencies."@dotfiles/librechat-code-bridge" = "workspace:*";
    };
    "packages/runtime/dist/index.js" = ''
      export { value } from "@dotfiles/librechat-code-bridge";
    '';
    "packages/codeapi-bridge/package.json" = builtins.toJSON {
      name = "@dotfiles/librechat-code-bridge";
      version = "0.1.0";
      type = "module";
      exports = "./dist/index.js";
      files = ["dist"];
    };
    "packages/codeapi-bridge/dist/index.js" = ''
      export const value = 42;
    '';
  };
in
  runCommandLocal "librechat-runtime-deployment-test" {
    nativeBuildInputs = [nix nodejs_24 pnpm];
    passthru.ci.runOnce = true;
  } ''
    base="$PWD"
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    pnpm config set store-dir "$base/store"

    for build in first second; do
      workspace="$base/$build"
      mkdir -p "$workspace"
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (path: contents: ''
        mkdir -p "$workspace/$(dirname ${lib.escapeShellArg path})"
        printf '%s' ${lib.escapeShellArg contents} >"$workspace/${path}"
      '')
      files)}

      cd "$workspace"
      pnpm install --offline --ignore-scripts --no-frozen-lockfile --store-dir "$base/store"
      deployment="$base/deployed-$build/lib/librechat-runtime"
      source ${./deploy.bash} "$deployment"
      cd "$base"
      rm -rf "$workspace"

      test "$(node "$deployment/dist/index.js")" = '{"value":42,"external":"production dependency"}'
      test ! -e "$deployment/.workspace/node_modules/fixture-dev"
      test -z "$(find "$deployment" -name fixture-dev -print -quit)"
      while IFS= read -r -d $'\0' link; do
        target=$(realpath -e "$link")
        case "$target" in
          "$deployment"/*) ;;
          *) printf 'Dependency link escapes the deployment: %s\n' "$link" >&2; exit 1 ;;
        esac
      done < <(find "$deployment" -type l -print0)
      nix-store --dump "$deployment" >"$base/$build.nar"
    done

    cmp first.nar second.nar
    touch "$out"
  ''
