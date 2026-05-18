# wolfictl CLI — packaged from GitHub release binaries.
# To update: ./pkgs/wolfictl/update.sh
{
  fetchurl,
  lib,
  stdenv,
  stdenvNoCC,
}: let
  sources = lib.importJSON ./sources.json;
  inherit (stdenv.hostPlatform) system;
  platform =
    sources.platforms.${system}
    or (throw "wolfictl: unsupported system ${system}");
in
  stdenvNoCC.mkDerivation {
    pname = "wolfictl";
    inherit (sources) version;

    src = fetchurl {
      inherit (platform) url hash;
    };

    dontUnpack = true;

    # Static Go binary (CGO_ENABLED=0), no patching needed.

    installPhase = ''
      runHook preInstall
      install -Dm755 "$src" "$out/bin/wolfictl"
      runHook postInstall
    '';

    postInstall = ''
      mkdir -p "$out/share/bash-completion/completions"
      mkdir -p "$out/share/zsh/site-functions"
      mkdir -p "$out/share/fish/vendor_completions.d"
      "$out/bin/wolfictl" completion bash > "$out/share/bash-completion/completions/wolfictl"
      "$out/bin/wolfictl" completion zsh > "$out/share/zsh/site-functions/_wolfictl"
      "$out/bin/wolfictl" completion fish > "$out/share/fish/vendor_completions.d/wolfictl.fish"
    '';

    meta = {
      description = "CLI for working with the Wolfi OSS project";
      homepage = "https://github.com/wolfi-dev/wolfictl";
      license = lib.licenses.asl20;
      platforms = builtins.attrNames sources.platforms;
      mainProgram = "wolfictl";
    };
  }
