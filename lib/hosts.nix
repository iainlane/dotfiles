# Host discovery: load every machine definition under `hosts/` into a single
# attrset keyed by hostname. Both flat (`hosts/foo.nix`) and directory-based
# (`hosts/foo/default.nix`) layouts are supported so hosts that need extra
# files (hardware, disks) can keep them alongside their record.
{
  lib,
  discovery,
}: let
  inherit (discovery) fileNames directoryNames;
in {
  # Hosts from `hosts/*.nix` and `hosts/*/default.nix`, keyed by name.
  hosts = let
    # File-based hosts: hosts/foo.nix -> { name = "foo"; value = ...; }
    fileHosts =
      map
      (filename: {
        name = lib.removeSuffix ".nix" filename;
        value = import (../hosts + "/${filename}");
      })
      (fileNames ../hosts ".nix");

    # Directory-based hosts: hosts/foo/default.nix -> { name = "foo"; ... }
    dirHosts =
      map
      (dirname: {
        name = dirname;
        value = import (../hosts + "/${dirname}/default.nix");
      })
      (builtins.filter
        (dirname:
          builtins.pathExists (../hosts + "/${dirname}/default.nix"))
        (directoryNames ../hosts));
  in
    lib.listToAttrs (fileHosts ++ dirHosts);
}
