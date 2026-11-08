{lib, ...}: let
  source = lib.fileset.toSource {
    root = ../../..;
    fileset = lib.fileset.unions [
      ../../../justfile
      ../../../scripts/check-evaluation.bash
      ../../../scripts/check-evaluation.test.bash
      ../../../scripts/check.test.bash
      ../../../flake/fixtures/evaluation.nix
      ../../../lib/nix/evaluation.conf
    ];
  };
in
  {pkgs, ...}:
    {
      checks.evaluation-gate =
        pkgs.runCommandLocal "evaluation-gate" {
          nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.just pkgs.nix];
        } ''
          bash ${source}/scripts/check-evaluation.test.bash \
            ${source}/scripts/check-evaluation.bash \
            ${source}/flake/fixtures/evaluation.nix
          bash ${source}/scripts/check.test.bash ${source}
          touch "$out"
        '';
    }.checks
