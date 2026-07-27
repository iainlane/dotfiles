{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.podman;
  podmanModule = "${inputs.home-manager}/modules/services/podman/linux";
  podmanLib = import "${podmanModule}/podman-lib.nix" {inherit config lib pkgs;};
  activation = import "${podmanModule}/activation.nix" {
    inherit config;
    podman-lib = podmanLib;
  };

  buildPodmanQuadlet = quadlet: let
    quadletFile = pkgs.writeText "${quadlet.serviceName}.${quadlet.resourceType}" quadlet.source;
  in
    pkgs.stdenv.mkDerivation {
      name = "home-${quadlet.resourceType}-${quadlet.serviceName}";

      src = quadletFile;

      buildInputs = [cfg.package] ++ quadlet.dependencies;

      unpackPhase = ''
        mkdir -p $out/quadlets
        ln -s $src $out/quadlets/${quadlet.serviceName}.${quadlet.resourceType}
        ${lib.concatStringsSep "\n" (
          map (
            dependency: "ln -s ${dependency.out}/quadlets/${dependency.quadletData.serviceName}.${dependency.quadletData.resourceType} $out/quadlets"
          )
          quadlet.dependencies
        )}
      '';

      installPhase = ''
        mkdir -p $out/units
        export QUADLET_UNIT_DIRS=$out/quadlets
        ${cfg.package}/lib/systemd/user-generators/podman-user-generator $out/units
      '';

      passthru = {
        outPath = lib.self.out;
        quadletData = quadlet;
      };
    };

  builtQuadlets = map buildPodmanQuadlet cfg.internal.quadletDefinitions;

  # The unit tree remains a derivation dependency so evaluating a home closure
  # does not realise the containers referenced by its quadlets.
  unitTree = pkgs.symlinkJoin {
    name = "home-podman-units";
    paths = map (quadlet: "${quadlet}/units") builtQuadlets;
  };
in {
  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isLinux) {
    home.file = lib.mkIf (builtQuadlets != []) {
      "${config.xdg.configHome}/systemd/user" = {
        source = unitTree;
        recursive = true;
      };
    };

    home.activation.podmanQuadletCleanup = lib.mkIf (builtQuadlets != []) (
      lib.hm.dag.entryAfter ["reloadSystemd"] activation.cleanup
    );

    services.podman.internal.builtQuadlets = lib.listToAttrs (
      map (package: {
        name =
          "${lib.removePrefix "podman-" package.passthru.quadletData.serviceName}."
          + package.passthru.quadletData.resourceType;
        value = package;
      })
      builtQuadlets
    );
  };
}
