{
  config,
  lib,
  ...
}: let
  operatingSystems = import ../../../lib/operating-systems.nix;
  cacheSettings = import ../../../lib/nix/cache-settings.nix;
  nixbuild = import ../../../lib/nixbuild.nix {inherit lib;};
  cupboard = cacheSettings.binaryCaches."cupboard.supply/t/laney";
  cupboardSubstituter = cupboard.substituter or "https://cupboard.supply/t/laney";
  isNixbuildSubstituter = uri: let
    match = builtins.match "ssh(-ng)?://([^/?]+).*" uri;
    authority = lib.elemAt match 1;
    hostname = lib.head (lib.splitString ":" (lib.last (lib.splitString "@" authority)));
  in
    match != null && lib.elem hostname [nixbuild.builderAlias nixbuild.hostName];
in {
  perSystem = {
    pkgs,
    system,
    ...
  }: let
    hosts = lib.filterAttrs (_: host: host.system == system) config.flake.hosts;
    failures = lib.concatLists (lib.mapAttrsToList (hostname: host: let
      inherit (operatingSystems.${host.os}) outputName;
      configuration = config.flake.${outputName}.${hostname}.config;
      settings =
        if host.os == "darwin"
        then configuration.determinateNix.customSettings
        else configuration.nix.settings;
      inherit (settings) substituters;
    in
      lib.optional (lib.any isNixbuildSubstituter substituters) "${hostname}: nixbuild.net is still a substituter"
      ++ lib.optional (!(lib.elem cupboardSubstituter substituters)) "${hostname}: cupboard.supply is missing from the substituters")
    hosts);
  in {
    checks.host-evaluation-caches = pkgs.runCommandLocal "host-evaluation-caches" {} (
      if failures == []
      then "touch $out"
      else throw (lib.concatStringsSep "\n" failures)
    );
  };
}
