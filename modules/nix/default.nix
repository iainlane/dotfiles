{lib, ...}: let
  cacheSettings = import ../../lib/nix/cache-settings.nix;
  nixbuild = import ../../profiles/nixbuild-common.nix {inherit lib;};

  cacheEntries =
    lib.mapAttrsToList
    (
      name: cache: let
        substituter =
          if cache ? substituter && cache.substituter != null
          then cache.substituter
          else "https://${name}";
        publicKeyName =
          if cache ? publicKeyName && cache.publicKeyName != null
          then cache.publicKeyName
          else name;
      in {
        inherit substituter;
        publicKey = "${publicKeyName}-1:${cache.key}";
      }
    );

  substitutersOf = caches: map (cache: cache.substituter) (cacheEntries caches);
  trustedPublicKeysOf = caches: map (cache: cache.publicKey) (cacheEntries caches);

  # A nix.conf fragment trusting the public caches plus the nixbuild.net remote
  # store key, for an environment that starts without the substituter trust the
  # hosts carry (such as a single-user Nix on a fresh runner). nixbuild-action
  # adds the `ssh://nixbuild` substituter itself where it offloads, so only the
  # signing key is needed, and that key is harmless where nixbuild is absent.
  substituterConfig = ''
    extra-substituters = ${lib.concatStringsSep " " (substitutersOf cacheSettings.binaryCaches)}
    extra-trusted-public-keys = ${lib.concatStringsSep " " (trustedPublicKeysOf (cacheSettings.binaryCaches // {nixbuild = nixbuild.binaryCaches.${nixbuild.builderAlias};}))}
  '';

  substitutersModule = {
    config,
    lib,
    ...
  }: let
    binaryCacheType = lib.types.submodule {
      options = {
        key = lib.mkOption {
          type = lib.types.str;
        };
        publicKeyName = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        substituter = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
      };
    };

    caches = cacheSettings.binaryCaches // config.dotfiles.nix.binaryCaches;
  in {
    options.dotfiles.nix = {
      binaryCaches = lib.mkOption {
        type = lib.types.attrsOf binaryCacheType;
        default = {};
      };
    };

    config = let
      sharedSettings = {
        substituters = substitutersOf caches;
        trusted-public-keys = trustedPublicKeysOf caches;
        trusted-users = cacheSettings.trustedUsers;
        builders-use-substitutes = true;
        extra-experimental-features = ["configurable-impure-env"];
      };
    in {
      _module.args.nixCacheSettings = sharedSettings;

      # On Linux, system-manager writes nix.settings to `/etc/nix/nix.conf`,
      # which is redirected to `/etc/nix/nix.custom.conf` for Determinate Nix.
      # On Darwin, the Determinate nix-darwin module handles this via
      # `determinateNix.customSettings` instead.
      nix.settings = sharedSettings;
    };
  };
in {
  flake.nix.substitutersModule = substitutersModule;
  flake.nix.substituterConfig = substituterConfig;
}
