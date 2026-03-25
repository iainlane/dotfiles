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

  # Default attribute path from directory path (user-facing).
  # "dev/debian" -> "dev.debian"
  defaultAttrPath = dirPath:
    lib.concatStringsSep "." (
      lib.filter (s: s != "") (lib.splitString "/" dirPath)
    );

  # Convert user-facing attr path to internal tree structure path.
  # "dev.debian" -> ["dev" "subdirectories" "debian" "shell"]
  toTreePath = attrPath: let
    segments = lib.splitString "." attrPath;
    first = lib.head segments;
    rest = lib.tail segments;
  in
    [first]
    ++ lib.concatMap (seg: ["subdirectories" seg]) rest
    ++ ["shell"];

  # Resolve a directory path to absolute.
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
            attrPath = mkOption {
              type = types.str;
              default = defaultAttrPath name;
              description = ''Attribute path (relative to the namespace) for this directory's dev shell'';
              example = "dev.debian";
            };

            extraPaths = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "Extra directories to prepend to PATH via direnv PATH_add.";
              example = lib.literalExpression ''["$HOME/go/bin"]'';
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
        treePath = [cfg.attrNamespace system] ++ toTreePath dirConfig.attrPath;
        shellAttr = lib.attrByPath treePath null inputs.self.outputs;
      in {
        assertion = shellAttr != null;
        message = "programs.projectDirectories: missing devShell ${lib.concatStringsSep "." treePath} for ${dirPath} in inputs.self outputs";
      })
      cfg.directories;

    home.file =
      lib.mapAttrs' (dirPath: dirConfig: let
        treePath = [cfg.attrNamespace system] ++ toTreePath dirConfig.attrPath;
        flakeAttr = lib.concatStringsSep "." treePath;
        shellAttr = lib.attrByPath treePath null inputs.self.outputs;
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
            rm -rf ${lib.escapeShellArg "${absoluteDir}/.direnv"}
            ${config.programs.direnv.package}/bin/direnv allow ${lib.escapeShellArg absoluteDir}
          '';
        };
      })
      cfg.directories;
  };
}
