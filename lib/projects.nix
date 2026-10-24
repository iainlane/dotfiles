# Project shell construction and Home Manager directory configuration.
{lib}: {
  mkProjectShell = {
    pkgs,
    def,
    base ? {},
    environment ? {},
  }:
    pkgs.mkShellNoCC (
      base
      // environment
      // {
        packages = (base.packages or []) ++ (def.extraPackages or (_: [])) pkgs;
      }
    );

  mkProjectShells = {
    projects,
    mkShell,
  }: {
    homeManagerModule = {
      pkgs-unstable,
      hostConfig,
      ...
    }: {
      imports = [./project-directories];
      programs.projectDirectories = {
        enable = true;
        directories = lib.mapAttrs' (_: def:
          lib.nameValuePair def.directory (
            {shell = mkShell pkgs-unstable (lib.systems.elaborate hostConfig.system) def;}
            // lib.optionalAttrs (def ? extraPaths) {inherit (def) extraPaths;}
          ))
        projects;
      };
    };
  };
}
