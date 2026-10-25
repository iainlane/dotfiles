{
  flake.features.inference.provides.librechat.checks = {pkgs, ...}: {
    inherit (pkgs) librechat-runtime;
  };
}
