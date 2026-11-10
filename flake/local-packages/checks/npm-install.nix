{pkgs}: let
  inherit (pkgs) lib;
  shared =
    (pkgs.callPackage ../../../lib/build-typescript-package.nix {
      buildNpmPackage = attrs: attrs {finalPackage = null;};
    }) {
      pname = "cleanup-fixture";
      version = "1";
      directory = ../../../pkgs/pi-planning;
      postCheck = ''touch post-check'';
    };
  piDiff = pkgs.callPackage ../../../pkgs/pi-diff/package.nix {
    buildNpmPackage = lib.id;
  };
  cases = [
    {
      name = "shared";
      hook = shared.postCheck or "";
      expected = "node_modules/runtime/index.js\npost-check\n";
    }
    {
      name = "pi-diff";
      hook = piDiff.postCheck or "";
      expected = "node_modules/runtime/index.js\n";
    }
  ];
in {
  npm-install-cleanup =
    pkgs.runCommandLocal "npm-install-cleanup" {
      nativeBuildInputs = [pkgs.diffutils];
      passthru.ci.runOnce = true;
    } (lib.concatMapStringsSep "\n" (test: ''
        mkdir ${test.name}
        (
          cd ${test.name}
          mkdir -p node_modules/.vite/vitest node_modules/runtime
          printf '%s\n' '{"duration":123}' >node_modules/.vite/vitest/results.json
          printf '%s\n' 'export default 1;' >node_modules/runtime/index.js
          ${test.hook}
          find . -type f -printf '%P\n' | sort >../actual
          printf '%s' ${lib.escapeShellArg test.expected} >../expected
          diff -u ../expected ../actual
        )
      '')
      cases
      + ''
        touch "$out"
      '');
}
