{
  inputs,
  system,
}: let
  repair = _: previous: {
    deploy-rs =
      previous.deploy-rs
      // {
        deploy-rs = previous.deploy-rs.deploy-rs.overrideAttrs (old: {
          patches = (old.patches or []) ++ [./native-confirmation-tests.patch];
        });
      };
  };
  pkgs = import inputs.deploy-rs.inputs.nixpkgs {
    inherit system;
    overlays = [inputs.deploy-rs.overlays.default repair];
  };
in
  pkgs.deploy-rs
