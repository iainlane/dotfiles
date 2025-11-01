{
  inputs,
  config,
  withSystem,
  ...
}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};
  inherit (inputs.nixpkgs) lib;

  projects = let
    defaults = {
      name = "Iain Lane";
    };
  in {
    dev-grafana =
      defaults
      // {
        directory = "dev/grafana";
        email = "iain@grafana.com";
        gpgKey = "0xAB2F5FB2C0B9FCE22B9D773B3B590AA273354714";
        zshColour = "cyan";
        packages = pkgs: [
          pkgs.go
          pkgs.go-jsonnet
          pkgs.tanka
        ];
      };
  };

  mkShell = pkgs: def:
    pkgs.mkShellNoCC (
      {
        packages = def.packages or (_: []) pkgs;
      }
      // {
        NAME = def.name;
        EMAIL = def.email;
        GIT_AUTHOR_NAME = def.name;
        GIT_AUTHOR_EMAIL = def.email;
        GIT_COMMITTER_EMAIL = def.email;
      }
      // lib.optionalAttrs (def ? gpgKey && def.gpgKey != null) {
        GPGKEY = def.gpgKey;
      }
      // lib.optionalAttrs (def ? zshColour && def.zshColour != null) {
        ZSH_USERNAME_COLOUR = def.zshColour;
      }
    );

  projectShells = helpers.mkProjectShells {
    inherit config withSystem mkShell projects;
  };
in {
  imports = [projectShells.flakeModule];

  flake.homeManagerModules.work = {
    pkgs,
    system,
    ...
  } @ args:
    lib.recursiveUpdate
    (projectShells.homeManagerModule args)
    {
      home.packages =
        [
          (inputs.rustanka.packages.${system}.rtk.overrideAttrs {doCheck = false;})
        ]
        ++ (with pkgs; [
          conftest
          jsonnet-bundler
          regal
          vale
        ]);
    };
}
