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
      in {
        inherit (cache) publicKeys;
        inherit substituter;
      }
    );

  substitutersOf = caches: map (cache: cache.substituter) (cacheEntries caches);
  trustedPublicKeysOf = caches: lib.concatMap (cache: cache.publicKeys) (cacheEntries caches);

  ciBinaryCaches =
    cacheSettings.binaryCaches // {nixbuild = nixbuild.binaryCaches.${nixbuild.builderAlias};};

  # Substituters for the nixbuild.net remote builder used in CI. This can only
  # use HTTP substituters, since the builder is not configured with any SSH
  # keys.
  remoteSubstituters = lib.concatStringsSep "," (
    lib.filter (substituter: !lib.hasPrefix "ssh://" substituter)
    (substitutersOf cacheSettings.binaryCaches)
  );
  remoteTrustedKeys = lib.concatStringsSep "," (trustedPublicKeysOf ciBinaryCaches);

  # Substituters for `nix` used on the CI system itself.
  substituterConfig = ''
    extra-substituters = ${lib.concatStringsSep " " (substitutersOf cacheSettings.binaryCaches)}
    extra-trusted-public-keys = ${lib.concatStringsSep " " (trustedPublicKeysOf ciBinaryCaches)}
  '';

  substitutersModule = {
    config,
    lib,
    ...
  }: let
    binaryCacheType = lib.types.submodule {
      options = {
        publicKeys = lib.mkOption {
          type = lib.types.nonEmptyListOf lib.types.str;
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
  flake.nix = {
    inherit substitutersModule substituterConfig;

    publishInputs = {
      # The cupboard cache's public key, which the publish workflow pins so the
      # pushed artefacts are trusted without trusting every cupboard tenant.
      trustedPublicKey = lib.head cacheSettings.binaryCaches."cupboard.supply/t/laney".publicKeys;

      # The remote builder line for CI, which authenticates with the nixbuild.net
      # token in the workflow's SSH config rather than an identity file, so the
      # key-path column stays `-`.
      builders = "ssh://${nixbuild.hostName} ${lib.concatStringsSep "," nixbuild.systems} - ${toString nixbuild.maxJobs} ${toString nixbuild.speedFactor} ${lib.concatStringsSep "," nixbuild.supportedFeatures} -";

      builderKnownHosts = "${nixbuild.hostName} ${nixbuild.hostKey}";

      githubKnownHost = "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";

      inherit remoteSubstituters remoteTrustedKeys;
    };
  };
}
