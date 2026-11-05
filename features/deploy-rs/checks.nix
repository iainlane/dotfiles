{
  lib,
  hosts,
  nodes,
  deployLibFor,
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
    nativeHosts = lib.filterAttrs (_: host: host.system == system) hosts;
    nativeNodes = lib.intersectAttrs nativeHosts nodes;
  in
    lib.optionalAttrs (hosts != {}) {
      deploy-schema = lib.lazyDerivation {
        derivation = (deployChecks {nodes = schemaNodes;}).deploy-schema;
        passthru = {
          ci.runOnce = true;
          requiredSystemFeatures = [];
        };
      };
    }
    // lib.optionalAttrs (nativeHosts != {}) {
      deploy-activate = lib.lazyDerivation {
        derivation = (deployChecks {nodes = nativeNodes;}).deploy-activate;
        passthru.requiredSystemFeatures = [];
      };
    }
