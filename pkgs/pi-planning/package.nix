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
  dependencyHash = "sha256-5n+WJHp9xggkE0wvTaPMCT8DLnA+lot865kisGTJ3NQ=";
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
