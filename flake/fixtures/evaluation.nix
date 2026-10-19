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
in {
  inherit package;
  sourceRead = builtins.readFile source;
  derivationRead = builtins.readFile package;
}
