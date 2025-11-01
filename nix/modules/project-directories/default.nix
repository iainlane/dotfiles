{
  config,
  lib,
  pkgs,
  inputs,
  system,
  flakePath,
  ...
}: let
  cfg = config.programs.projectDirectories;
  inherit (lib) mkOption types;

  defaultAttrPath = path:
    lib.concatStringsSep "." (
      lib.filter (segment: segment != "") (lib.splitString "/" path)
    );
in {
  options.programs.projectDirectories = {
    enable = lib.mkEnableOption "project directory .envrc management";

    flakePath = mkOption {
      type = types.str;
      default = flakePath;
      defaultText = lib.literalExpression "flakePath";
      description = "Path to the flake exposing direnv devShells to load";
      example = lib.literalExpression ''"''${config.home.homeDirectory}/path/to/flake"'';
    };

    attrNamespace = mkOption {
      type = types.str;
      default = "direnvs";
      description = "Attribute namespace in the flake that contains direnv devShells";
    };

    directories = mkOption {
      type = types.attrsOf (
        types.submodule ({name, ...}: {
          options = {
            attrPath = mkOption {
              type = types.str;
              default = defaultAttrPath name;
              description = ''Attribute path (relative to the namespace) for this directory's dev shell'';
              example = "dev.debian";
            };

            flakePath = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Override the global flake path for this directory";
            };
          };
        })
      );
      default = {};
      example = lib.literalExpression ''
        {
          "dev/debian" = {
            attrPath = "dev.debian";
          };
          "dev/ubuntu" = {
            flakePath = "/path/to/alternate/flake";
          };
        }
      '';
      description = "Project directories and the flake attributes they should load";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.programs.direnv.enable;
        message = "programs.projectDirectories requires programs.direnv.enable = true";
      }
    ];

    home.file =
      lib.mapAttrs' (path: dirConfig: let
        dirFlakePath =
          if dirConfig.flakePath == null
          then cfg.flakePath
          else dirConfig.flakePath;
        attrSelector = "${cfg.attrNamespace}.${system}.${dirConfig.attrPath}";

        # Try to get the actual devShell derivation to track changes. This only
        # works for inputs.self (not external flakes). We use
        # `unsafeDiscardOutputDependency` to get the .drv path without forcing
        # evaluation/download of all build dependencies.
        shellAttr =
          if dirConfig.flakePath == null
          then
            lib.attrByPath
            (lib.splitString "." attrSelector)
            null
            inputs.self.outputs
          else null;

        # Include derivation path as a comment so .envrc changes when the shell
        # changes and we trigger the `onChange` hook.
        derivationComment =
          if shellAttr != null && shellAttr ? drvPath
          then "# ${builtins.unsafeDiscardOutputDependency shellAttr.drvPath}\n"
          else "# External flake: manual cache invalidation required\n";
      in {
        name = "${path}/.envrc";
        value = {
          text = derivationComment + "use flake \"${dirFlakePath}#${attrSelector}\"\n";
          # Auto-approve the .envrc on changes. This is safe because we generate
          # it from Nix; no risk of loading untrusted direnv files. We also
          # remove the .direnv cache to force a rebuild with the new
          # environment.
          onChange = ''
            rm -rf ~/${path}/.direnv
            ${pkgs.direnv}/bin/direnv allow ~/${path}
          '';
        };
      })
      cfg.directories;
  };
}
