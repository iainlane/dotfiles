# Chainguard chainctl CLI — packaged from dl.enforce.dev binary releases.
# To update: nix run .#update-chainctl
{
  autoPatchelfHook,
  fetchurl,
  gnugrep,
  lib,
  stdenv,
  stdenvNoCC,
  updaters,
}: let
  sources = lib.importJSON ./sources.json;
  inherit (stdenv.hostPlatform) system;

  # Nix system → chainctl artifact suffix.
  platforms = {
    "x86_64-linux" = "linux_x86_64";
    "aarch64-linux" = "linux_arm64";
    "x86_64-darwin" = "darwin_x86_64";
    "aarch64-darwin" = "darwin_arm64";
  };

  platform =
    sources.platforms.${system}
    or (throw "chainctl: unsupported system ${system}");

  hostSuffix = platforms.${system};
in
  stdenvNoCC.mkDerivation {
    pname = "chainctl";
    inherit (sources) version;

    src = fetchurl {
      inherit (platform) url hash;
    };

    dontUnpack = true;

    nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [
      autoPatchelfHook
    ];

    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
      stdenv.cc.cc.lib
    ];

    installPhase = ''
      runHook preInstall
      install -Dm755 "$src" "$out/bin/chainctl"

      # docker-credential-cgr must be on PATH for Docker credential helpers.
      # `chainctl auth configure-docker` tries to symlink this next to the
      # binary, which fails in the read-only Nix store.
      ln -s chainctl "$out/bin/docker-credential-cgr"

      runHook postInstall
    '';

    postInstall = ''
      mkdir -p "$out/share/bash-completion/completions"
      mkdir -p "$out/share/zsh/site-functions"
      mkdir -p "$out/share/fish/vendor_completions.d"

      "$out/bin/chainctl" completion bash > "$out/share/bash-completion/completions/chainctl"
      "$out/bin/chainctl" completion zsh > "$out/share/zsh/site-functions/_chainctl"
      "$out/bin/chainctl" completion fish > "$out/share/fish/vendor_completions.d/chainctl.fish"
    '';

    passthru.updateScript = updaters.mkSourcesUpdater {
      pname = "chainctl";
      inherit platforms;
      extraRuntimeInputs = [gnugrep];

      # The vendor exposes no version metadata, so download the latest binary
      # for the host platform and ask it, keeping the updater runnable on both
      # Linux and Darwin.
      discoverVersion = ''
        echo "Discovering latest version..." >&2
        tmp="$(mktemp)"
        trap 'rm -f "''${tmp}"' EXIT
        download "https://dl.enforce.dev/chainctl/latest/chainctl_${hostSuffix}" "''${tmp}"
        chmod +x "''${tmp}"
        version="$("''${tmp}" version 2>&1 | grep -oP 'GitVersion:\s*\K\S+')"
      '';
      urlTemplate = "https://dl.enforce.dev/chainctl/\${version}/chainctl_\${suffix}";
    };

    meta = {
      description = "CLI for the Chainguard platform";
      homepage = "https://edu.chainguard.dev/chainguard/chainctl-usage/";
      license = lib.licenses.asl20;
      platforms = builtins.attrNames platforms;
      mainProgram = "chainctl";
    };
  }
