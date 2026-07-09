# Filesystem discovery helpers: turn directory layouts into lists of paths and
# imported values. These are the primitives the flake uses to auto-discover
# hosts, profiles, modules, packages, and overlays without hand-maintained
# import lists.
{lib}: rec {
  # Sorted names for one `builtins.readDir` entry type. Examples of entry types
  # are `"regular"` and `"directory"`. Pass `""` for `suffix` to disable suffix
  # filtering.
  entryNames = dir: entryType: suffix:
    builtins.attrNames (
      lib.filterAttrs (
        name: entryType':
          entryType'
          == entryType
          && lib.hasSuffix suffix name
      )
      (builtins.readDir dir)
    );

  # Sorted regular file names from a directory. Pass `""` for `suffix` to
  # include all regular files.
  fileNames = dir: suffix: entryNames dir "regular" suffix;

  # Sorted directory names from a directory.
  directoryNames = dir: entryNames dir "directory" "";

  # Discover flake-parts modules: list subdirectories of `dir` that contain a
  # `default.nix` and return paths to those files.
  discoverModules = dir:
    map
    (name: dir + "/${name}/default.nix")
    (builtins.filter
      (name: builtins.pathExists (dir + "/${name}/default.nix"))
      (directoryNames dir));

  # Discover local packages: list subdirectory names of `dir` that contain a
  # `package.nix`. Used by the `pkgs/` layout to surface packages both as an
  # overlay and as flake outputs without repeating the file layout in each
  # consumer.
  discoverPackages = dir:
    builtins.filter
    (name: builtins.pathExists (dir + "/${name}/package.nix"))
    (directoryNames dir);

  # Import all `.nix` files from a directory as a list. Each file may either be
  # a plain value or a function that accepts `args`.
  importNixFiles = dir: args:
    map
    (filename: let
      loaded = import (dir + "/${filename}");
    in
      if builtins.isFunction loaded
      then loaded args
      else loaded)
    (fileNames dir ".nix");
}
