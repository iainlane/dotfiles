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
  # "dev/debian" → "dev.debian"
  defaultAttrPath = dirPath:
    lib.concatStringsSep "." (
      lib.filter (s: s != "") (lib.splitString "/" dirPath)
    );

  # Convert user-facing attr path to internal tree structure path.
  # "dev.debian" → ["dev" "subdirectories" "debian" "shell"]
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
      # Fail early if the referenced devShell does not exist. This prevents
      # silently generating .envrc files that won't work.
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

        # Get the devShell derivation to track changes. We use
        # `unsafeDiscardOutputDependency` to get the .drv path without forcing
        # evaluation/download of all build dependencies.
        shellAttr = lib.attrByPath treePath null inputs.self.outputs;

        # Include derivation path as a comment so .envrc changes when the shell
        # changes and we trigger the `onChange` hook.
        derivationComment = "# ${builtins.unsafeDiscardOutputDependency shellAttr.drvPath}\n";

        absoluteDir = toAbsolute dirPath;
      in {
        name = "${dirPath}/.envrc";
        value = {
          text =
            derivationComment
            + "source_up_if_exists\n"
            + "use flake \"${flakePath}#${flakeAttr}\"\n";
          # Auto-approve the .envrc on changes. This is safe because we generate
          # it from Nix; no risk of loading untrusted direnv files. We also
          # remove the .direnv cache to force a rebuild with the new
          # environment.
          onChange = ''
            rm -rf ${lib.escapeShellArg "${absoluteDir}/.direnv"}
            ${pkgs.direnv}/bin/direnv allow ${lib.escapeShellArg absoluteDir}
          '';
        };
      })
      cfg.directories;
  };
}
