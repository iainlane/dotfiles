{lib}: let
  policy = import ./package-maintenance.nix {inherit lib;};
  valid = maintenance: script:
    policy.errors {
      name = "fixture";
      package = {
        inherit maintenance;
        updateScript = script;
      };
      packages = ["provider" "fixture"];
      inputs = ["nixpkgs"];
    };
  executable = {
    type = "derivation";
    outPath = "/nix/store/fixture-updater";
  };
in
  assert valid {source = "repository";} null == [];
  assert valid {
    source = "input";
    inputs = ["nixpkgs"];
  }
  null
  == [];
  assert valid {
    source = "derived";
    dependencies = ["provider"];
  }
  null
  == [];
  assert valid {
    source = "release";
    refresh = true;
  }
  executable
  == [];
  assert valid {
    source = "pin";
    reason = "The fork includes required fixes.";
  }
  null
  == [];
  assert valid {source = "unknown";} null != [];
  assert valid {
    source = "input";
    inputs = ["missing"];
  }
  null
  != [];
  assert valid {
    source = "derived";
    dependencies = ["missing"];
  }
  null
  != [];
  assert valid {source = "pin";} null != [];
  assert valid {
    source = "repository";
    refresh = true;
  }
  null
  != [];
  assert valid {source = "repository";} ["upstream-script"] != [];
  assert valid {
    source = "repository";
    temporary = true;
  }
  null
  != []; true
