{
  config,
  lib,
  pkgs,
  inputs,
  system,
  flakePath,
  ...
}:
# Generate per-directory `.envrc` files that load flake-based devShells via
# direnv. This allows us to centrally define development environments for
# particular directories.
let
  cfg = config.programs.projectDirectories;
  inherit (lib) mkOption types;

  defaultAttrPath = path:
    lib.concatStringsSep "." (
      lib.filter (segment: segment != "") (lib.splitString "/" path)
    );
in {
  options.programs.projectDirectories = {
    enable = lib.mkEnableOption "automatic .envrc generation for project directories";

    attrNamespace = mkOption {
      type = types.str;
      default = "direnvs";
      description = ''
        Attribute prefix inside this flake that holds the devShells.
        This module expects a structure like: direnvs.<system>.<attrPath>.
      '';
    };

    directories = mkOption {
      type = types.attrsOf (
        types.submodule ({name, ...}: {
          options = {
            attrPath = mkOption {
              type = types.str;
              default = defaultAttrPath name;
              description = ''
                Attribute path (relative to the namespace) for this directory's
                devShell. For "dev/debian", the default is "dev.debian".
              '';
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
      description = ''
        Map of project directories to the devShell attribute they should load.
        Each directory gets a generated .envrc pointing at
        direnvs.<system>.<attrPath> in this flake.
      '';
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
      # When using the default flake, fail early if the referenced devShell does
      # not exist. This prevents us from silently generating .envrc files that
      # won't work.
      ++ lib.mapAttrsToList (path: dirConfig: let
        attrSelector = "${cfg.attrNamespace}.${system}.${dirConfig.attrPath}";
        shellAttr =
          lib.attrByPath
          (lib.splitString "." attrSelector)
          null
          inputs.self.outputs;
      in {
        assertion = shellAttr != null;
        message = "programs.projectDirectories: missing devShell ${attrSelector} for ${path} in inputs.self outputs";
      })
      cfg.directories;

    home.file =
      lib.mapAttrs' (path: dirConfig: let
        dirFlakePath = flakePath;
        attrSelector = "${cfg.attrNamespace}.${system}.${dirConfig.attrPath}";

        # Try to obtain the devShell derivation path so changes to the shell
        # cause the .envrc to change. This only works for inputs.self, and we
        # use `unsafeDiscardOutputDependency` to avoid pulling in build inputs.
        shellAttr =
          lib.attrByPath
          (lib.splitString "." attrSelector)
          null
          inputs.self.outputs;

        # Include the derivation path as a comment so .envrc changes trigger the
        # onChange hook when the shell changes.
        derivationComment = "# ${builtins.unsafeDiscardOutputDependency shellAttr.drvPath}\n";
        # Resolve the directory to an absolute path so the activation hook can
        # handle spaces and other shell-sensitive characters safely.
        absoluteDir =
          if lib.hasPrefix "/" path
          then path
          else "${config.home.homeDirectory}/${path}";
      in {
        name = "${path}/.envrc";
        value = {
          text = derivationComment + "use flake \"${dirFlakePath}#${attrSelector}\"\n";
          # Auto-approve generated .envrc files and clear the cache so direnv
          # rebuilds the environment when the shell changes.
          onChange = ''
            rm -rf ${lib.escapeShellArg "${absoluteDir}/.direnv"}
            ${pkgs.direnv}/bin/direnv allow ${lib.escapeShellArg absoluteDir}
          '';
        };
      })
      cfg.directories;
  };
}
