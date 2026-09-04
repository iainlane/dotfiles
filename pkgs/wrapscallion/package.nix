# wrapscallion commit message linter — packaged from GitHub release binaries.
# To update: nix run .#update-wrapscallion
{
  autoPatchelfHook,
  curl,
  fetchurl,
  lib,
  stdenv,
  stdenvNoCC,
  updaters,
}: let
  sources = lib.importJSON ./sources.json;
  inherit (stdenv.hostPlatform) system isLinux;

  # Nix system → Rust target triple in the release asset name.
  platforms = {
    "x86_64-linux" = "x86_64-unknown-linux-gnu";
    "aarch64-linux" = "aarch64-unknown-linux-gnu";
    "x86_64-darwin" = "x86_64-apple-darwin";
    "aarch64-darwin" = "aarch64-apple-darwin";
  };

  platform =
    sources.platforms.${system}
    or (throw "wrapscallion: unsupported system ${system}");
in
  stdenvNoCC.mkDerivation {
    pname = "wrapscallion";
    inherit (sources) version;

    src = fetchurl {
      inherit (platform) url hash;
    };

    dontUnpack = true;

    nativeBuildInputs = lib.optionals isLinux [
      autoPatchelfHook
    ];

    buildInputs = lib.optionals isLinux [
      stdenv.cc.cc.lib
    ];

    # `deno compile` appends the program after the ELF image and finds it at
    # runtime through a trailer at the end of the file, which records how far
    # back the program starts. Patch the bare image, then put the program back
    # behind it so the trailer is at the end again.
    dontAutoPatchelf = true;

    installPhase =
      ''
        runHook preInstall
      ''
      + lib.optionalString isLinux ''
        program=$(tail -c 8 "$src" | od -An -tu8 | tr -d ' ')
        head -c $(($(stat -c %s "$src") - program)) "$src" >"$out/bin/wrapscallion"
      ''
      + lib.optionalString (!isLinux) ''
        install -Dm755 "$src" "$out/bin/wrapscallion"
      ''
      + ''
        runHook postInstall
      '';

    preInstall = lib.optionalString isLinux ''
      mkdir -p "$out/bin"
    '';

    postFixup = lib.optionalString isLinux ''
      autoPatchelf "$out/bin"
      tail -c "$program" "$src" >>"$out/bin/wrapscallion"
      chmod 755 "$out/bin/wrapscallion"
    '';

    doInstallCheck = true;

    installCheckPhase = ''
      runHook preInstallCheck
      "$out/bin/wrapscallion" --help >/dev/null
      runHook postInstallCheck
    '';

    passthru.updateScript = updaters.mkSourcesUpdater {
      pname = "wrapscallion";
      inherit platforms;
      extraRuntimeInputs = [curl];

      discoverVersion = ''
        echo "Fetching latest version..." >&2
        tag="$(curl -fsSL "https://api.github.com/repos/underwhelmingperformance/wrapscallion/releases/latest" | jq -r .tag_name)"
        version="''${tag#v}"
      '';
      urlTemplate = "https://github.com/underwhelmingperformance/wrapscallion/releases/download/\${tag}/wrapscallion-\${version}-\${suffix}";
    };

    meta = {
      description = "Linter for Conventional Commit messages and 72-column bodies";
      homepage = "https://github.com/underwhelmingperformance/wrapscallion";
      license = lib.licenses.mit;
      platforms = builtins.attrNames platforms;
      mainProgram = "wrapscallion";
    };
  }
