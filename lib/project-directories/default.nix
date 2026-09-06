{
  config,
  lib,
  inputs,
  system,
  flakePath,
  ...
}: let
  cfg = config.programs.projectDirectories;
  inherit (lib) mkOption types;

  # `mkProjectShells` builds the `direnvs` tree with these same two helpers,
  # so this module looks a shell up under the path that shell was registered
  # at.
  inherit (import ../projects.nix {inherit lib;}) directorySegments treePath;

  toAbsolute = dirPath:
    if lib.hasPrefix "/" dirPath
    then dirPath
    else "${config.home.homeDirectory}/${dirPath}";
in {
  options.programs.projectDirectories = {
    enable = lib.mkEnableOption "project directory .envrc management";

    attrNamespace = mkOption {
      type = types.str;
      default = "direnvs";
      description = "Attribute namespace in the flake that contains direnv devShells";
    };

    directories = mkOption {
      type = types.attrsOf (
        types.submodule ({name, ...}: {
          options = {
            attrSegments = mkOption {
              type = types.listOf types.str;
              default = directorySegments name;
              description = ''The segments naming this directory's dev shell under the namespace.'';
              example = ["dev" "debian"];
            };

            extraPaths = mkOption {
              type = types.listOf types.str;
              default = [];
              description = ''
                Extra directories to prepend to PATH via direnv PATH_add. Each
                value is written to the `.envrc` unquoted, so the shell expands
                it: only use values that are safe to expand.
              '';
              example = lib.literalExpression ''["$HOME/go/bin"]'';
            };
          };
        })
      );
      default = {};
      example = lib.literalExpression ''
        {
          "dev/debian" = {
            attrSegments = ["dev" "debian"];
          };
        }
      '';
      description = "Project directories and the flake attributes they should load";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      [
        {
          assertion = config.programs.direnv.enable;
          message = "programs.projectDirectories requires programs.direnv.enable = true";
        }
      ]
      ++ lib.mapAttrsToList (dirPath: dirConfig: let
        shellPath = [cfg.attrNamespace system] ++ treePath dirConfig.attrSegments;
        shellAttr = lib.attrByPath shellPath null inputs.self.outputs;
      in {
        assertion = shellAttr != null;
        message = "programs.projectDirectories: missing devShell ${lib.concatStringsSep "." shellPath} for ${dirPath} in inputs.self outputs";
      })
      cfg.directories;

    home.file =
      lib.mapAttrs' (dirPath: dirConfig: let
        shellPath = [cfg.attrNamespace system] ++ treePath dirConfig.attrSegments;
        flakeAttr = lib.concatStringsSep "." shellPath;
        shellAttr = lib.attrByPath shellPath null inputs.self.outputs;
        derivationComment = "# ${builtins.unsafeDiscardStringContext shellAttr.drvPath}\n";
        absoluteDir = toAbsolute dirPath;
      in {
        name = "${dirPath}/.envrc";
        value = {
          text =
            derivationComment
            + "source_up_if_exists\n"
            + "use flake \"${flakePath}#${flakeAttr}\"\n"
            + lib.concatMapStrings (p: "PATH_add ${p}\n") dirConfig.extraPaths;
          onChange = ''
            ${config.programs.direnv.package}/bin/direnv allow ${lib.escapeShellArg absoluteDir}
          '';
        };
      })
      cfg.directories;
  };
}
