{
  inputs,
  lib,
  hosts,
  nodes,
  deployLibFor ? system: (import ../../lib/deploy-rs {inherit inputs system;}).lib,
}: let
  # Schema validation must not realise every deployment profile.
  schemaNodes =
    lib.mapAttrs (
      _: node:
        node
        // {
          profiles = lib.mapAttrs (_: profile:
            profile // {path = builtins.unsafeDiscardStringContext "${profile.path}";})
          node.profiles;
        }
    )
    nodes;
in
  {system, ...}: let
    inherit (deployLibFor system) deployChecks;
    nativeNodes = lib.filterAttrs (hostname: _: hosts.${hostname}.system == system) nodes;
  in {
    deploy-schema = lib.lazyDerivation {
      derivation = (deployChecks {nodes = schemaNodes;}).deploy-schema;
      passthru = {
        ci.runOnce = true;
        requiredSystemFeatures = [];
      };
    };
    deploy-activate = lib.lazyDerivation {
      derivation = (deployChecks {nodes = nativeNodes;}).deploy-activate;
      passthru.requiredSystemFeatures = [];
    };
  }
