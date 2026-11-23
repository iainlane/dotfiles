let
  available = {
    maintained = {
      drvPath = "/nix/store/maintained.drv";
      maintenance = {
        inputs = ["source"];
        refreshInputs = ["toolchain"];
        dependencies = ["without-updater"];
      };
    };
    without-updater = {
      drvPath = "/nix/store/without-updater.drv";
      maintenance = {
        inputs = ["provider-source"];
        refreshInputs = "stale";
      };
    };
    without-policy.drvPath = "/nix/store/without-policy.drv";
  };
  node = import ./package-node.nix {
    inherit available;
    localPackages =
      available
      // {
        unavailable.maintenance.refreshInputs = ["toolchain"];
      };
    metadata = {
      maintained.refresh = true;
      unavailable.refresh = true;
    };
    scripts = {
      maintained = {};
      unavailable = {};
    };
  };
  actual = map node ["maintained" "without-updater" "unavailable" "without-policy" "absent"];
  expected = [
    {
      name = "maintained";
      path = "/nix/store/maintained.drv";
      updater = true;
      refresh = true;
      inputs = ["source" "toolchain"];
      dependencies = ["without-updater"];
    }
    {
      name = "without-updater";
      path = "/nix/store/without-updater.drv";
      updater = false;
      refresh = false;
      inputs = ["provider-source"];
      dependencies = null;
    }
    {
      name = "unavailable";
      path = null;
      updater = true;
      refresh = true;
      inputs = ["toolchain"];
      dependencies = null;
    }
    {
      name = "without-policy";
      path = "/nix/store/without-policy.drv";
      updater = false;
      refresh = false;
      inputs = [];
      dependencies = null;
    }
    {
      name = "absent";
      path = null;
      updater = false;
      refresh = false;
      inputs = [];
      dependencies = null;
    }
  ];
in
  assert actual == expected; true
