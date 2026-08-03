# Discover and expose shared skill directories from ./skills/, plus skills
# published in external repositories and consumed as flake inputs.
#
# Returns { name = <path>; } for each skill, suitable for passing directly to
# programs.<tool>.skills.
{
  inputs,
  lib,
}: let
  dir = ./skills;

  subdirs =
    lib.filterAttrs
    (_name: type: type == "directory")
    (builtins.readDir dir);

  local =
    lib.mapAttrs
    (name: _: dir + "/${name}")
    subdirs;

  external = {
    gh-stack = "${inputs.gh-stack-skill}/skills/gh-stack";
  };
in
  local // external
