# A JavaScript library from npm, installed under `js/<library>/<version>/` where
# LaraPaper's renderer configuration expects it. That configuration also
# decides the version, so the updater reads the version from LaraPaper's
# composer vendor tree.
{
  lib,
  runCommand,
  fetchurl,
  writeShellApplication,
  git,
  nix,
  python3,
  # The npm package name, which is also the directory under `js/`.
  library,
  # The parsed `source.json`, with the npm `version` and the archive's `hash`.
  source,
  # Destination file name for each file to install, mapped to its path inside
  # the npm archive.
  files,
}: let
  pname = "larapaper-${library}";
  inherit (source) version;

  archive = fetchurl {
    url = "https://registry.npmjs.org/${library}/-/${library}-${version}.tgz";
    inherit (source) hash;
  };

  installFiles = lib.concatStringsSep "\n" (lib.mapAttrsToList (destination: path: ''
      cp package/${lib.escapeShellArg path} "$directory"/${lib.escapeShellArg destination}
    '')
    files);
in
  runCommand "${pname}-${version}" {
    inherit pname version;

    passthru.updateScript = writeShellApplication {
      name = "update-${pname}";

      runtimeInputs = [git nix python3];

      text = ''
        cd "$(git rev-parse --show-toplevel)/pkgs/${pname}"

        python3 ${./update.py} ${lib.escapeShellArg library} "$@"
      '';
    };

    meta.platforms = lib.platforms.all;
  } ''
    tar -xf ${archive}
    directory="$out/js/${library}/${version}"
    mkdir -p "$directory"
    ${installFiles}
  ''
