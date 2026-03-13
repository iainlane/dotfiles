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

    config = {
      # On Darwin, we write `nix.custom.conf` directly since `nix-darwin` doesn't
      # support `nix.settings.substituters` yet.
      _module.args.substitutersCustomConf = ''
        substituters = ${lib.concatStringsSep " " substituters}
        trusted-public-keys = ${lib.concatStringsSep " " trustedPublicKeys}
        trusted-users = ${lib.concatStringsSep " " cacheSettings.trustedUsers}
        builders-use-substitutes = true
      '';

      # On Linux we can use nix.settings via system-manager. Normally this would
      # update `/etc/nix/nix.conf`, but on Determinate Nix this is owned by the
      # system itself, so a few lines below here we redirect this to
      # `/etc/nix/nix.custom.conf`.
      nix.settings = {
        inherit substituters;
        trusted-public-keys = trustedPublicKeys;
        trusted-users = cacheSettings.trustedUsers;
      };
    };
  };
in {
  flake.nix.substitutersModule = substitutersModule;
}
