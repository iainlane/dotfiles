_: let
  cacheSettings = import ../../lib/nix/cache-settings.nix;
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

    binaryCaches =
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
      )
      (cacheSettings.binaryCaches // config.dotfiles.nix.binaryCaches);

    substituters = map (cache: cache.substituter) binaryCaches;
    trustedPublicKeys = map (cache: cache.publicKey) binaryCaches;
  in {
    options.dotfiles.nix = {
      binaryCaches = lib.mkOption {
        type = lib.types.attrsOf binaryCacheType;
        default = {};
      };
    };

    config = let
      sharedSettings = {
        inherit substituters;
        trusted-public-keys = trustedPublicKeys;
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
}
