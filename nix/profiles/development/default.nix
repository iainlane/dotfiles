{
  inputs,
  config,
  withSystem,
  ...
}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};
  inherit (inputs.nixpkgs) lib;

  # Base dev directory with common tools
  projects = {
    dev = {
      directory = "dev";
      packages = pkgs:
        with pkgs; [
          just
        ];
    };

    dev-random-rust = {
      directory = "dev/random/rust";
      packages = pkgs: let
        inherit (pkgs) fenix;
        stableToolchain = fenix.stable.withComponents [
          "cargo"
          "clippy"
          "rust-src"
          "rustc"
          "rustfmt"
        ];
        nightlyRustfmt = fenix.complete.withComponents ["rustfmt"];
      in [
        stableToolchain
        nightlyRustfmt
        fenix.rust-analyzer
      ];
    };

    dev-random-go = {
      directory = "dev/random/go";
      packages = pkgs:
        with pkgs; [
          go
          gopls
          golangci-lint
          delve
        ];
    };

    dev-random-python = {
      directory = "dev/random/python";
      packages = pkgs:
        with pkgs; [
          python3
          uv
          ruff
          pyright
        ];
    };

    dev-random-typescript = {
      directory = "dev/random/typescript";
      packages = pkgs:
        with pkgs; [
          nodejs
          pnpm
          typescript
          nodePackages.typescript-language-server
        ];
    };

    dev-random-lua = {
      directory = "dev/random/lua";
      packages = pkgs:
        with pkgs; [
          lua
          luarocks
          lua-language-server
        ];
    };
  };

  mkShell = pkgs: def:
    pkgs.mkShell {
      packages = (def.packages or (_: [])) pkgs;
    };

  projectShells = helpers.mkProjectShells {
    inherit config withSystem mkShell projects;
  };
in {
  imports = [projectShells.flakeModule];

  flake.homeManagerModules.development = {pkgs, ...} @ args:
    lib.recursiveUpdate
    (projectShells.homeManagerModule args)
    {
      home.packages = with pkgs; [
        terraform

        kubectl
        kubernetes-helm
        jq
        yq-go

        cosign
        crane
        dive
        go-containerregistry
        grype
        oras
        syft

        act
        actionlint
        codeowners
        shellcheck

        stylua
        tokei
        twiggy

        tldr

        zizmor
      ];

      programs.mise = {
        enable = true;
        enableZshIntegration = true;

        globalConfig = {
          settings = {
            experimental = true;

            idiomatic_version_file_enable_tools = ["node" "python"];

            not_found_auto_install = true;
          };
        };
      };
    };
}
