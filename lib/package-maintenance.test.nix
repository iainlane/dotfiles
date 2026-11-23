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
    refreshInputs = ["nixpkgs"];
  }
  executable
  == [];
  assert valid {
    source = "release";
    refresh = true;
  }
  executable
  == ["fixture: refresh-capable packages must declare refreshInputs using declared flake inputs"];
  assert valid {
    source = "release";
    refresh = true;
    refreshInputs = ["missing"];
  }
  executable
  == ["fixture: refresh-capable packages must declare refreshInputs using declared flake inputs"];
  assert valid {
    source = "release";
    refreshInputs = ["nixpkgs"];
  }
  executable
  == ["fixture: refreshInputs requires refresh capability"];
  assert valid {
    source = "pin";
    reason = "The fork includes required fixes.";
  }
  null
  == [];
  assert valid {
    source = "repository";
    lockfileMaintenance = true;
  }
  executable
  == [];
  assert valid {
    source = "repository";
    lockfileMaintenance = true;
  }
  null
  == ["fixture: lockfile maintenance capability requires a local updater"];
  assert valid {
    source = "repository";
    lockfileMaintenance = "yes";
  }
  executable
  == ["fixture: lockfile maintenance capability requires a local updater"];
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
