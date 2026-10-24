{
  callPackage,
  lib,
  runCommandLocal,
  upstreamNodejs,
}: let
  accepts = overrides: (builtins.tryEval (callPackage ./package.nix ({inherit upstreamNodejs;} // overrides)).pname).success;
  cases = [
    {
      upstream = null;
      expected = true;
    }
    {
      upstream.version = "6.5.0";
      expected = true;
    }
    {
      upstream.version = "6.7.0";
      expected = true;
    }
    {
      upstream.version = "6.7.1";
      expected = false;
    }
    {
      upstream.version = "6.8.0";
      expected = false;
    }
  ];
  nodeCases = [
    {
      version = "24.21.0";
      expected = true;
    }
    {
      version = "24.22.0";
      expected = true;
    }
    {
      version = "24.22.1";
      expected = false;
    }
    {
      version = "24.23.0";
      expected = false;
    }
  ];
in
  assert lib.assertMsg (lib.all (case: accepts {upstreamRea = case.upstream;} == case.expected) cases)
  "REA's local package must reject nixpkgs releases at or after 6.7.1.";
  assert lib.assertMsg (lib.all (case:
    accepts {
      upstreamRea = null;
      upstreamNodejs.version = case.version;
    }
    == case.expected)
  nodeCases)
  "REA's Node fallback must reject nixpkgs Node 24.22.1 or newer.";
    runCommandLocal "rea-upstream-version" {} ''
      touch "$out"
    ''
