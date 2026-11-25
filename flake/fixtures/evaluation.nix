let
  text = "evaluation fixture\n";
  source = builtins.toFile "evaluation-input" text;
  package = builtins.derivation {
    name = "evaluation-fixture";
    system = builtins.currentSystem;
    builder = "builtin:fetchurl";
    url = "file://${source}";
    outputHash = builtins.hashString "sha256" text;
    outputHashAlgo = "sha256";
    outputHashMode = "flat";
  };

  target = system: cohort: suffix: {
    inherit system cohort;
    rootSuffix = "${system}/${suffix}";
    rootDrvPath = package.drvPath;
  };

  x86 = target "x86_64-linux" "x86_64-linux";
in {
  inherit package;
  targets =
    [
      (target "aarch64-darwin" "aarch64-darwin-deploy" "darwin-host")
      (target "aarch64-linux" "aarch64-linux" "checks-example")
      (target "x86_64-linux" "x86_64-linux-deploy" "checks-deploy-activate")
      (x86 "packages")
      (x86 "slow-checks-podman-oci-containers-example")
      (x86 "slow-checks-podman-podman-example")
      (x86 "slow-checks-another")
    ]
    ++ builtins.genList (i: x86 "checks-${toString i}") 49;
  ifdTarget = [
    ((x86 "checks-ifd")
      // {
        rootDrvPath = builtins.readFile package;
      })
  ];
  sourceRead = builtins.readFile source;
  derivationRead = builtins.readFile package;
}
