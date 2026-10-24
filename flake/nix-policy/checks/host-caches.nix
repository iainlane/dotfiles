{
  hosts,
  lib,
  hostResults,
  featureResolver,
  ...
}: let
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
in
  {
    pkgs,
    system,
    ...
  }:
    (
      let
        nativeHosts = lib.filterAttrs (_: host: host.system == system) hosts;
        failures = lib.concatLists (lib.mapAttrsToList (hostname: host: let
          configuration = hostResults.${hostname}.configuration.config;
          settings =
            if featureResolver.isDarwin (featureResolver.contextForHost host)
            then configuration.determinateNix.customSettings
            else configuration.nix.settings;
          inherit (settings) substituters;
        in
          lib.optional (lib.any isNixbuildSubstituter substituters) "${hostname}: nixbuild.net is still a substituter"
          ++ lib.optional (!(lib.elem cupboardSubstituter substituters)) "${hostname}: cupboard.supply is missing from the substituters")
        nativeHosts);
      in {
        checks.host-evaluation-caches = pkgs.runCommandLocal "host-evaluation-caches" {} (
          if failures == []
          then "touch $out"
          else throw (lib.concatStringsSep "\n" failures)
        );
      }
    ).checks
