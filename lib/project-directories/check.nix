{
  inputs,
  pkgs,
  lib,
  ...
}: let
  inherit (import ../projects.nix {inherit lib;}) mkProjectShell mkProjectShells;
  directory = "dev/project's space.with-dots";
  projectShells = mkProjectShells {
    projects.example = {
      inherit directory;
      extraPackages = packages: [packages.hello];
      extraPaths = ["$HOME/go/bin"];
    };
    mkShell = packages: platform: def:
      mkProjectShell {
        pkgs = packages;
        inherit def;
        environment = {
          PROJECT_DIRECTORY_SYSTEM = platform.system;
          shellHook = "export PROJECT_DIRECTORY_TEST=loaded";
        };
      };
  };
  home =
    (import ../home.nix {
      inherit inputs lib;
      featureResolver = {};
    }).mkHomeConfiguration {
      homeManager = inputs.home-manager;
      pkgs = pkgs // {mkShellNoCC = _: throw "project shells used the home package channel";};
      extraSpecialArgs = {
        pkgs-unstable = pkgs;
        hostConfig = {
          name = "fixture-host";
          system = pkgs.stdenv.hostPlatform.system;
        };
        flakePath = "/repo with spaces";
      };
      modules = [
        projectShells.homeManagerModule
        {
          home = {
            username = "fixture";
            homeDirectory = "/home/fixture";
            stateVersion = "25.11";
          };
          programs.direnv.enable = true;
        }
      ];
    };
  inherit (home) config;
  shell = config.programs.projectDirectories.directories.${directory}.shell;
  expectedInstallable = ''/repo with spaces#"homeResults"."fixture@fixture-host"."config"."programs"."projectDirectories"."directories"."dev/project's space.with-dots"."shell"'';
  actual = {
    directories = lib.attrNames config.programs.projectDirectories.directories;
    dependencies = map toString config.home.extraDependencies;
    envrc = config.home.file."${directory}/.envrc".text;
    envrcContext = builtins.getContext config.home.file."${directory}/.envrc".text;
    packages = map toString shell.nativeBuildInputs;
    system = shell.PROJECT_DIRECTORY_SYSTEM;
    inherit (shell) shellHook;
  };
  expected = {
    directories = [directory];
    dependencies = [shell.outPath];
    envrc = ''
      # ${builtins.unsafeDiscardStringContext shell.drvPath}
      source_up_if_exists
      use flake ${lib.escapeShellArg expectedInstallable}
      PATH_add $HOME/go/bin
    '';
    envrcContext = {};
    packages = [pkgs.hello.outPath];
    system = pkgs.stdenv.hostPlatform.system;
    shellHook = "export PROJECT_DIRECTORY_TEST=loaded";
  };
  closure = pkgs.closureInfo {rootPaths = [home.activationPackage];};
in {
  project-directories = assert lib.assertMsg (actual == expected) "Project directory configuration differs from the expected host-owned shell.";
    pkgs.runCommandLocal "project-directories" {
      nativeBuildInputs = [pkgs.gnugrep];
      envrc = config.home.file."${directory}/.envrc".source;
    } ''
      export HOME="$TMPDIR/home"
      source_up_if_exists() { printf '%s\0' ancestor >>actual; }
      use() { printf '%s\0' use "$@" >>actual; }
      PATH_add() { printf '%s\0' PATH_add "$@" >>actual; }
      source "$envrc"
      printf '%s\0' ancestor use flake \
        ${lib.escapeShellArg expectedInstallable} \
        PATH_add "$HOME/go/bin" >expected
      cmp expected actual

      grep -Fx ${lib.escapeShellArg shell.outPath} ${closure}/store-paths
      grep -Fx ${lib.escapeShellArg pkgs.hello.outPath} ${closure}/store-paths
      if grep -E '\.drv$' ${closure}/store-paths; then
        echo 'The home closure retains derivations.' >&2
        exit 1
      fi
      touch "$out"
    '';

  project-directory-refresh =
    pkgs.runCommandLocal "project-directory-refresh" {
      nativeBuildInputs = [pkgs.bash pkgs.coreutils];
    } ''
      bash ${./refresh.test.bash} \
        ${../../scripts/refresh-direnvs.bash} \
        ${../../scripts/lib/just-common.bash}
      touch "$out"
    '';
}
