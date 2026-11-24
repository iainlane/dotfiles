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
  updaters,
}:
buildNpmPackage (finalAttrs: {
  pname = "rea";
  version = "6.9.0";
  __structuredAttrs = true;

  src = fetchFromGitHub {
    owner = "morluto";
    repo = "rea";
    rev = "rea-agents-6.9.0";
    hash = "sha256-n96fXl7OKRIlQ/nKGBDjN8kT4RIr2atgrQAU379lsoQ=";
  };

  patches = [./external-tools.patch ./ghidra-version-policy.patch];

  # Starting the packaged JVM can exceed five seconds on a cold runner.
  postPatch = ''
    substituteInPlace src/ghidra/GhidraJavaProbe.ts \
      --replace-fail 'production five-second deadline' 'production 30-second deadline' \
      --replace-fail 'timeoutMs: options.timeoutMs ?? 5000' 'timeoutMs: options.timeoutMs ?? 30_000'
  '';

  npmDepsHash = "sha256-xFNYn2vxfk8unZyJQ3YWOO3fFb3iJVU6Alav0A+TiSI=";
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
      refresh = true;
      refreshInputs = ["nixpkgs" "nixpkgs-stable"];
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
        inherit lib runCommandLocal;
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
