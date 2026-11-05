{
  lib,
  stdenv,
  buildNpmPackage,
  fetchFromGitHub,
  fetchNpmDeps,
  installAgentSkills,
  installShellFiles,
  makeWrapper,
  autoPatchelfHook,
  nodejs,
  procps,
  python3,
  runCommand,
  runCommandLocal,
  callPackage,
  updaters,
  upstreamNodejs,
  upstreamRea ? null,
}: let
  firstFixedRelease = "6.7.1";
in
  assert lib.assertMsg (lib.versionOlder upstreamNodejs.version "24.22.1") ''
    nixpkgs now provides Node ${upstreamNodejs.version}. Remove REA's stable
    Node fallback and use nodejs_24 from the regular nixpkgs input.
  '';
  assert lib.assertMsg (upstreamRea == null || lib.versionOlder upstreamRea.version firstFixedRelease) ''
    nixpkgs now provides REA ${upstreamRea.version}. Verify setup policy
    preservation and external-tool integration, then replace the local package.
  '';
    buildNpmPackage (finalAttrs: {
      pname = "rea";
      version = "6.8.0";
      __structuredAttrs = true;

      src = fetchFromGitHub {
        owner = "morluto";
        repo = "rea";
        rev = "rea-agents-6.8.0";
        hash = "sha256-2ADn3U3lvUoB4tCEpzO0rMfYE4sis+5uBiEazcp0gpI=";
      };

      patches = [./external-tools.patch ./ghidra-version-policy.patch];

      npmDepsHash = "sha256-3WPXD+qm5WVfrTEvepKwX5RZBfbLBcPB0uDmKIx4MR8=";
      npmDeps = fetchNpmDeps {
        name = "${finalAttrs.pname}-${finalAttrs.version}-npm-deps";
        inherit (finalAttrs) src;
        hash = finalAttrs.npmDepsHash;
      };
      npmFlags = ["--ignore-scripts"];
      npmBuildScript = "compile";
      postBuild = "node scripts/generate-skill-metadata.mjs";

      inherit nodejs;

      nativeBuildInputs =
        [installAgentSkills installShellFiles]
        ++ lib.optionals stdenv.hostPlatform.isLinux [makeWrapper autoPatchelfHook];
      buildInputs = lib.optional stdenv.hostPlatform.isLinux stdenv.cc.cc.lib;

      preBuild = lib.optionalString stdenv.hostPlatform.isLinux ''
        autoPatchelf node_modules/@tsrs
      '';

      dontInstallAgentSkills = true;

      postInstall =
        ''
          rm -rf "$out/lib/node_modules/rea-agents/node_modules/frida"
          installSkill skills/reverse-engineer-anything rea
        ''
        + lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
          "$out/bin/rea" completions bash > rea.bash
          "$out/bin/rea" completions fish > rea.fish
          "$out/bin/rea" completions nushell > rea.nu
          "$out/bin/rea" completions zsh > rea.zsh
          installShellCompletion rea.{bash,fish,nu,zsh}
        ''
        + lib.optionalString stdenv.hostPlatform.isLinux ''
          wrapProgram "$out/bin/rea" --prefix PATH : ${lib.makeBinPath [procps]}
          wrapProgram "$out/bin/rea-agents" --prefix PATH : ${lib.makeBinPath [procps]}
        '';

      passthru = {
        updateScript = updaters.mkNixUpdateUpdater {
          attr = "rea";
          extraFlags = [
            "--version=stable"
            "--use-github-releases"
            "--version-regex=^rea-agents-([0-9]+\\.[0-9]+\\.[0-9]+)$"
          ];
        };
        tests = {
          setup-policy = runCommand "rea-setup-policy" {nativeBuildInputs = [python3];} ''
            python3 ${./package.test.py} ${finalAttrs.finalPackage}
            touch "$out"
          '';
          python-version-policy = runCommand "rea-python-version-policy" {nativeBuildInputs = [python3];} ''
            python3 ${./python-version-policy.test.py} ${finalAttrs.finalPackage}
            touch "$out"
          '';
          version-policy = runCommand "rea-version-policy" {} ''
            ${nodejs}/bin/node ${./version-policy.test.mjs} ${finalAttrs.finalPackage}
            touch "$out"
          '';
          upstream-version = import ./upstream-version-check.nix {
            inherit callPackage lib runCommandLocal upstreamNodejs;
          };
        };
      };

      meta = {
        description = "Reverse-engineering CLI and MCP server";
        homepage = "https://github.com/morluto/rea";
        license = lib.licenses.mit;
        mainProgram = "rea";
        platforms = lib.platforms.linux ++ lib.platforms.darwin;
      };
    })
