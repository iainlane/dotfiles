# Chainguard chainctl CLI — packaged from dl.enforce.dev binary releases.
# To update: ./modules/chainctl/update.sh
{inputs, ...}: let
  inherit (inputs.nixpkgs) lib;
  sources = lib.importJSON ./sources.json;

  homeManagerModule = {pkgs, ...}: let
    system = pkgs.stdenv.hostPlatform.system;
    platform =
      sources.platforms.${system}
        or (throw "chainctl: unsupported system ${system}");

    chainctl = pkgs.stdenvNoCC.mkDerivation {
      pname = "chainctl";
      inherit (sources) version;

      src = pkgs.fetchurl {
        inherit (platform) url hash;
      };

      dontUnpack = true;

      nativeBuildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
        pkgs.autoPatchelfHook
      ];

      buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
        pkgs.stdenv.cc.cc.lib
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

      meta = {
        description = "CLI for the Chainguard platform";
        homepage = "https://edu.chainguard.dev/chainguard/chainctl-usage/";
        license = lib.licenses.asl20;
        platforms = builtins.attrNames sources.platforms;
        mainProgram = "chainctl";
      };
    };
  in {
    home.packages = [chainctl];
  };
in {
  flake.modules.chainctl.homeManagerModules = [homeManagerModule];
}
