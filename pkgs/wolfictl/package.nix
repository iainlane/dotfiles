# wolfictl CLI — packaged from GitHub release binaries.
# To update: nix run .#update-wolfictl
{
  curl,
  fetchurl,
  lib,
  stdenv,
  stdenvNoCC,
  updaters,
}: let
  sources = lib.importJSON ./sources.json;
  inherit (stdenv.hostPlatform) system;

  # Nix system → goreleaser os_arch suffix.
  platforms = {
    "x86_64-linux" = "linux_amd64";
    "aarch64-linux" = "linux_arm64";
    "x86_64-darwin" = "darwin_amd64";
    "aarch64-darwin" = "darwin_arm64";
  };

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

    passthru.updateScript = updaters.mkSourcesUpdater {
      pname = "wolfictl";
      inherit platforms;
      extraRuntimeInputs = [curl];

      discoverVersion = ''
        echo "Fetching latest version..." >&2
        tag="$(curl -fsSL "https://api.github.com/repos/wolfi-dev/wolfictl/releases/latest" | jq -r .tag_name)"
        version="''${tag#v}"
      '';
      urlTemplate = "https://github.com/wolfi-dev/wolfictl/releases/download/\${tag}/wolfictl_\${suffix}_\${version}_\${suffix}";
    };

    meta = {
      description = "CLI for working with the Wolfi OSS project";
      homepage = "https://github.com/wolfi-dev/wolfictl";
      license = lib.licenses.asl20;
      platforms = builtins.attrNames platforms;
      mainProgram = "wolfictl";
    };
  }
