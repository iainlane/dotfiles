{lib, ...}: {
  # Declare options for custom flake outputs so flake-parts knows how to merge
  # multiple definitions from different profile modules. Without these, each
  # profile trying to set these outputs causes a conflict.

  options.flake = {
    homeManagerModules = lib.mkOption {
      type = lib.types.lazyAttrsOf lib.types.unspecified;
      default = {};
      description = ''
        Home Manager modules exported by this flake. Each profile contributes
        its own module here.
      '';
    };

    direnvs = lib.mkOption {
      type = lib.types.lazyAttrsOf lib.types.unspecified;
      default = {};
      description = ''
        Nested direnv shells organised by system and directory path.
        Used by the project-directories home-manager module to generate
        .envrc files.
      '';
    };
  };
}
