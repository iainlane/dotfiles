{
  callPackage,
  lib,
  stdenv,
  upstreamPackage,
}: let
  npmPackages = import ../../lib/npm-packages.nix {inherit lib;};
  npmName = "@earendil-works/pi-coding-agent";
  sdkPackageRoot = "libexec/pi-sdk";
  npmPackHook = callPackage ../build-support/npm-pack-hook.nix {};
in
  upstreamPackage.overrideAttrs (finalAttrs: old: {
    patches = (old.patches or []) ++ [./native-call-label.patch ./native-message-errors.patch];
    buildInputs = (old.buildInputs or []) ++ lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];
    outputs = (old.outputs or ["out"]) ++ ["sdk" "tarball"];
    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [npmPackHook];
    preInstall = ''
      # The CLI selects its startup model before refreshing the remote catalogue.
      node --input-type=module <<'JS'
      import { readFileSync, writeFileSync } from "node:fs";

      const path = "node_modules/@earendil-works/pi-ai/dist/providers/data/openai.json";
      const catalogue = JSON.parse(readFileSync(path, "utf8"));
      const models = catalogue["openai-responses"];
      const id = "gpt-6.2-sol";

      if (!models["chat:" + id]) {
        const sol = models["chat:gpt-6.1-sol"];
        if (!sol) throw new Error("Pi's bundled catalogue has no GPT-6.1 Sol entry");

        models["chat:" + id] = { ...sol, id, name: "GPT-6.2 Sol" };
        writeFileSync(path, JSON.stringify(catalogue));
      }
      JS

      mkdir -p "$sdk/${sdkPackageRoot}"
      cp -a package.json package-lock.json README.md CHANGELOG.md dist docs examples node_modules "$sdk/${sdkPackageRoot}/"
      ${old.preInstall or ""}
    '';
    # dist/pi is the compiled CLI, which postInstall has already installed. The
    # npm release does not contain it, and it differs on each system, so the
    # packed tarball leaves it out.
    postInstall = ''
      ${old.postInstall or ""}
      rm dist/pi
    '';
    passthru =
      (old.passthru or {})
      // {
        updateScript = null;
        maintenance = {
          source = "input";
          inputs = ["llm-agents"];
        };

        npmTarball = "${finalAttrs.finalPackage.tarball}/package.tgz";
      };
    meta =
      old.meta
      // {
        identifiers.purlParts = npmPackages.purlParts {
          name = npmName;
          inherit (finalAttrs) version;
        };
      };
  })
