{
  inputs,
  config,
  withSystem,
  ...
}: let
  helpers = import ../helpers.nix {inherit inputs;};
  inherit (inputs.nixpkgs) lib;
  inherit (config.flake) mkLanguageShell;

  # Base dev directory with common tools
  projects = {
    dev = {
      directory = "dev";
      extraPackages = pkgs: with pkgs; [just];
    };

    dev-random-rust = {
      directory = "dev/random/rust";
      languages = ["rust"];
    };

    dev-random-go = {
      directory = "dev/random/go";
      languages = ["go"];
    };

    dev-random-python = {
      directory = "dev/random/python";
      languages = ["python"];
    };

    dev-random-typescript = {
      directory = "dev/random/typescript";
      languages = ["typescript"];
    };

    dev-random-lua = {
      directory = "dev/random/lua";
      languages = ["lua"];
    };
  };

  mkShell = pkgs: os: def: let
    langShell = mkLanguageShell pkgs os (def.languages or []);
    extra = (def.extraPackages or (_: [])) pkgs;
  in
    pkgs.mkShellNoCC (langShell
      // {
        packages = (langShell.packages or []) ++ extra;
      });

  projectShells = helpers.mkProjectShells {
    inherit config withSystem mkShell projects;
  };
in {
  imports = [
    projectShells.flakeModule
    ./darwin.nix
    ./linux.nix
    ./nixos.nix
  ];

  flake.profiles.development.homeManagerModule = {pkgs, ...} @ args:
    lib.recursiveUpdate
    (projectShells.homeManagerModule args)
    {
      home.packages = with pkgs; [
        terraform

        kubernetes-helm
        jq
        yq-go

        cosign
        crane
        dive
        docker-compose
        go-containerregistry
        grype
        oras
        podman
        podman-compose
        qemu
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
