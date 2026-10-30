{
  config,
  lib,
  hostConfig,
  flakePath,
  ...
}: let
  cfg = config.programs.projectDirectories;
  inherit (lib) mkOption types;

  toAbsolute = dirPath:
    if lib.hasPrefix "/" dirPath
    then dirPath
    else "${config.home.homeDirectory}/${dirPath}";
in {
  options.programs.projectDirectories = {
    enable = lib.mkEnableOption "project directory .envrc management";

    directories = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            shell = mkOption {
              type = types.package;
              description = "Development shell for this host's project directory.";
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
        }
      );
      default = {};
      example = lib.literalExpression ''
        {
          "dev/debian" = {
            shell = pkgs.mkShellNoCC {packages = [pkgs.git];};
          };
        }
      '';
      description = "Project directories and their development shells.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.programs.direnv.enable;
        message = "programs.projectDirectories requires programs.direnv.enable = true";
      }
    ];

    home.extraDependencies = map (directory: directory.shell) (builtins.attrValues cfg.directories);

    home.file =
      lib.mapAttrs' (dirPath: dirConfig: let
        flakeAttr =
          "."
          + lib.concatMapStringsSep "." builtins.toJSON [
            "homeResults"
            "${config.home.username}@${hostConfig.name}"
            "config"
            "programs"
            "projectDirectories"
            "directories"
            dirPath
            "shell"
          ];
        derivationComment = "# ${builtins.unsafeDiscardStringContext dirConfig.shell.drvPath}\n";
        absoluteDir = toAbsolute dirPath;
      in {
        name = "${dirPath}/.envrc";
        value = {
          text =
            derivationComment
            + "source_up_if_exists\n"
            + "use flake ${lib.escapeShellArg "${flakePath}#${flakeAttr}"}\n"
            + lib.concatMapStrings (p: "PATH_add ${p}\n") dirConfig.extraPaths;
          onChange = ''
            ${config.programs.direnv.package}/bin/direnv allow ${lib.escapeShellArg absoluteDir}
          '';
        };
      })
      cfg.directories;
  };
}
