{
  inputs,
  config,
  withSystem,
  ...
}: let
  helpers = import ../helpers.nix {inherit inputs;};
  inherit (inputs.nixpkgs) lib;
  langPackages = config.flake.direnvPackages;

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
      packages = langPackages.rust;
    };

    dev-random-go = {
      directory = "dev/random/go";
      packages = langPackages.go;
    };

    dev-random-python = {
      directory = "dev/random/python";
      packages = langPackages.python;
    };

    dev-random-typescript = {
      directory = "dev/random/typescript";
      packages = langPackages.typescript;
    };

    dev-random-lua = {
      directory = "dev/random/lua";
      packages = langPackages.lua;
    };
  };

  mkShell = pkgs: def:
    pkgs.mkShellNoCC {
      packages = (def.packages or (_: [])) pkgs;
    };

  projectShells = helpers.mkProjectShells {
    inherit config withSystem mkShell projects;
  };
in {
  imports = [
    projectShells.flakeModule
    ./darwin.nix
  ];

  flake.profiles.development.homeManagerModule = {pkgs, ...} @ args:
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
