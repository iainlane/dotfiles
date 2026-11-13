{
  callPackage,
  pi,
  pi-diff,
  pi-pretty,
  pi-subagents,
  pnpm_10,
}:
(callPackage ../build-support/pnpm-package.nix {}) {
  pname = "pi-planning";
  directory = ./.;
  pnpm = pnpm_10;
  dependencyHashes = {
    aarch64-darwin = "sha256-JW3WATPq91P7TzdIVdIFkjzamqslFZEqhWrFIcPLIi4=";
    aarch64-linux = "sha256-JW3WATPq91P7TzdIVdIFkjzamqslFZEqhWrFIcPLIi4=";
    x86_64-linux = "sha256-JW3WATPq91P7TzdIVdIFkjzamqslFZEqhWrFIcPLIi4=";
  };
  environment = {
    PI_TEST_HOST = "${pi}/bin/pi";
    PI_TEST_PRETTY = "${pi-pretty}/${pi-pretty.packageRoot}";
    PI_TEST_DIFF = "${pi-diff}/${pi-diff.packageRoot}";
    PI_TEST_SUBAGENTS = "${pi-subagents}/${pi-subagents.packageRoot}";
  };

  preCheck = ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
  '';
  postInstall = ''
    ln -s ${pi-subagents}/${pi-subagents.packageRoot} "$out/$packageRoot/node_modules/pi-subagents"
  '';
}
