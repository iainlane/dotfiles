# Discover and expose shared skill directories from ./skills/.
#
# Returns { name = ./skills/<name>; } for each subdirectory, suitable for
# passing directly to programs.<tool>.skills.
{lib}: let
  dir = ./skills;

  subdirs =
    lib.filterAttrs
    (_name: type: type == "directory")
    (builtins.readDir dir);
in
  lib.mapAttrs
  (name: _: dir + "/${name}")
  subdirs
