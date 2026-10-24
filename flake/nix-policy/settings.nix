{
  lib,
  config,
  ...
}: let
  cacheSettings = import ../../lib/nix/cache-settings.nix;
  nixbuild = import ../../lib/nixbuild.nix {inherit lib;};

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

  # Substituters for the nixbuild.net remote builder used in CI. The builder
  # has no SSH keys, so it gets the HTTP substituters from
  # `cacheSettings.binaryCaches` only. The trusted keys come from
  # `ciBinaryCaches`, which adds nixbuild's own key without adding its
  # `ssh://` substituter.
  remoteSubstituters = lib.concatStringsSep "," (substitutersOf cacheSettings.binaryCaches);
  remoteTrustedKeys = lib.concatStringsSep "," (trustedPublicKeysOf ciBinaryCaches);

  substituterConfigOf = caches: ''
    extra-substituters = ${lib.concatStringsSep " " (substitutersOf caches)}
    extra-trusted-public-keys = ${lib.concatStringsSep " " (trustedPublicKeysOf ciBinaryCaches)}
  '';

  # Substituters for `nix` used on the CI system itself.
  substituterConfig = substituterConfigOf cacheSettings.binaryCaches;

  # Nix netrc credentials apply to the whole host. The publisher's OIDC read
  # configuration must exclude the other tenant's releases cache.
  publishSubstituterConfig = substituterConfigOf (
    lib.removeAttrs cacheSettings.binaryCaches ["cupboard.supply/t/cupboard/cache/releases"]
  );

  evaluationConfig = builtins.readFile ../../lib/nix/evaluation.conf;
  ciConfig = evaluationConfig + substituterConfig;
  publishCiConfig = evaluationConfig + publishSubstituterConfig;

  substitutersModule = {config, ...}: let
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
        description = "Extra binary caches this host trusts, beyond the ones every host and CI share.";
      };
    };

    config = let
      settings = {
        substituters = substitutersOf caches;
        trusted-public-keys = trustedPublicKeysOf caches;
        trusted-users = cacheSettings.trustedUsers;
        builders-use-substitutes = true;
        extra-experimental-features = ["configurable-impure-env"];
      };
    in {
      # Under Determinate Nix, nix-darwin ignores `nix.settings`. Its adapter
      # applies these settings through `determinateNix.customSettings`.
      _module.args.nixCacheSettings = settings;

      # NixOS and the installer images render `nix.settings` into
      # `/etc/nix/nix.conf` in the ordinary way. Under system-manager,
      # `os/generic-linux/system.nix` disables the upstream nix module and
      # writes `/etc/nix/nix.custom.conf` from this attribute itself.
      nix.settings = settings;
    };
  };
in {
  options.flake.nix = lib.mkOption {
    readOnly = true;
    type = lib.types.submodule {
      options =
        lib.genAttrs ["substituterConfig" "publishSubstituterConfig" "ciConfig" "publishCiConfig"]
        (_: lib.mkOption {type = lib.types.str;})
        // {
          publishInputs = lib.mkOption {
            type = lib.types.submodule {
              options =
                lib.genAttrs ["trustedPublicKey" "builders" "builderKnownHosts" "githubKnownHost" "remoteSubstituters" "remoteTrustedKeys"]
                (_: lib.mkOption {type = lib.types.str;});
            };
          };
        };
    };
  };
  config.flake.nix = {
    inherit (config.dotfiles.nix) substituterConfig publishSubstituterConfig ciConfig publishCiConfig publishInputs;
  };
  options.dotfiles.nix = lib.mkOption {
    type = lib.types.submodule {
      options = {
        substitutersModule = lib.mkOption {
          type = lib.types.deferredModule;
          description = "Module setting the substituters and their public keys, applied by each OS adapter to whichever module system builds the host.";
        };
        substituterConfig = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Nix settings for shared binary caches.";
        };
        publishSubstituterConfig = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Nix cache settings for the laney publisher's OIDC read session.";
        };
        ciConfig = lib.mkOption {
          type = lib.types.str;
          description = "Nix evaluation policy and shared binary caches for configuration validation.";
        };
        publishCiConfig = lib.mkOption {
          type = lib.types.str;
          description = "Nix evaluation policy and caches for the laney publisher's OIDC read session.";
        };
        publishInputs = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          description = "Values the cupboard publish workflow writes into its own `nix.conf` and SSH config, where no module system is available.";
        };
      };
    };
    default = {};
  };

  config.dotfiles.nix = {
    inherit substitutersModule substituterConfig publishSubstituterConfig ciConfig publishCiConfig;

    publishInputs = {
      # The cupboard cache's public key. The publish workflow trusts this key
      # alone, so a path signed by another cupboard tenant is refused.
      trustedPublicKey = lib.head cacheSettings.binaryCaches."cupboard.supply/t/laney".publicKeys;

      # The builders setting for CI, with one entry for each system because
      # nixbuild.net supports different features on each. The workflow's SSH
      # config supplies the nixbuild.net token, so the key-path column is `-`.
      builders =
        lib.concatMapStringsSep ";" (system: "ssh://${nixbuild.hostName} ${system} - ${toString nixbuild.maxJobs} ${toString nixbuild.speedFactor} ${lib.concatStringsSep "," nixbuild.supportedFeatures.${system}} -")
        nixbuild.systems;

      builderKnownHosts = "${nixbuild.hostName} ${nixbuild.hostKey}";

      githubKnownHost = "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";

      inherit remoteSubstituters remoteTrustedKeys;
    };
  };
}
