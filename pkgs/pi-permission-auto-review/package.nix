{
  buildNpmPackage,
  fetchFromGitHub,
  importNpmLock,
  jq,
  lib,
  nodejs,
  pi-permission-system,
  runCommand,
}: let
  pin = lib.importJSON ./source.json;
  packageLock = lib.importJSON ./npm-deps/package-lock.json;
  manifest = packageLock.packages."";
  packageRoot = "lib/node_modules/@mzwing/pi-permission-auto-review";
  sandboxSource = fetchFromGitHub {
    owner = "underwhelmingperformance";
    repo = "pi-bring-your-own-sandbox";
    inherit (pin.sandboxSdk) rev hash;
  };
  sandboxTarball = runCommand "pi-bring-your-own-sandbox-0.0.0.tgz" {nativeBuildInputs = [nodejs];} ''
    export HOME="$TMPDIR/home"
    cp -R ${sandboxSource}/packages/sdk sdk
    chmod -R u+w sdk
    cp ${sandboxSource}/LICENSE sdk/LICENSE
    cd sdk
    npm pack --ignore-scripts --pack-destination "$TMPDIR"
    cp "$TMPDIR/pi-bring-your-own-sandbox-0.0.0.tgz" "$out"
  '';
in
  buildNpmPackage {
    pname = "pi-permission-auto-review";
    inherit (pin) version;

    src = fetchFromGitHub {
      owner = "iainlane";
      repo = "pi-packages";
      inherit (pin) rev hash;
    };
    sourceRoot = "source/packages/pi-permission-auto-review";

    nativeBuildInputs = [jq];
    postPatch = ''
      jq --argjson manifest ${lib.escapeShellArg (builtins.toJSON manifest)} \
        --arg sandbox "file:${sandboxTarball}" \
        '. + $manifest | .dependencies["pi-bring-your-own-sandbox"] = $sandbox' \
        package.json >package.json.new
      mv package.json.new package.json
    '';

    npmDeps = importNpmLock {
      npmRoot = ./npm-deps;
      package = manifest;
      inherit packageLock;
      packageSourceOverrides."node_modules/pi-bring-your-own-sandbox" = sandboxTarball;
    };
    inherit (importNpmLock) npmConfigHook;
    npmFlags = ["--ignore-scripts" "--legacy-peer-deps"];
    npmPruneFlags = ["--omit=peer" "--legacy-peer-deps"];
    npmPackFlags = ["--ignore-scripts"];

    postInstall = ''
      jq --arg dependency ${lib.escapeShellArg manifest.dependencies.pi-bring-your-own-sandbox} \
        '.dependencies["pi-bring-your-own-sandbox"] = $dependency' \
        "$out/${packageRoot}/package.json" >package.json.installed
      mv package.json.installed "$out/${packageRoot}/package.json"
      mkdir -p "$out/${packageRoot}/node_modules/@gotgenes"
      ln -s ${pi-permission-system}/${pi-permission-system.packageRoot} \
        "$out/${packageRoot}/node_modules/@gotgenes/pi-permission-system"
    '';

    passthru = {
      inherit packageRoot;
      updateScript = null;
      maintenance = {
        source = "pin";
        reason = "The permission adapter and sandbox SDK are reviewed together.";
      };
    };

    meta = {
      description = "Codex-style automatic permission reviews for Pi";
      homepage = "https://github.com/iainlane/pi-packages/tree/codex-parity/packages/pi-permission-auto-review";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
    };
  }
