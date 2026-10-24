{lib, ...}: let
  source = lib.fileset.toSource {
    root = ../../..;
    fileset = lib.fileset.unions [
      ../../../scripts/check-evaluation.bash
      ../../../scripts/check-evaluation.test.bash
      ../../../flake/fixtures/evaluation.nix
      ../../../lib/nix/evaluation.conf
    ];
  };
in
  {pkgs, ...}:
    {
      checks.evaluation-gate =
        pkgs.runCommandLocal "evaluation-gate" {
          nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.nix];
        } ''
          bash ${source}/scripts/check-evaluation.test.bash \
            ${source}/scripts/check-evaluation.bash \
            ${source}/flake/fixtures/evaluation.nix
          touch "$out"
        '';
    }.checks
