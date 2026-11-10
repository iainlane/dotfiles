let
  node = import ./package-node.nix {
    available = {
      maintained = {
        drvPath = "/nix/store/maintained.drv";
        maintenance.dependencies = ["without-updater"];
      };
      without-updater = {
        drvPath = "/nix/store/without-updater.drv";
        maintenance.source = "repository";
      };
      without-policy.drvPath = "/nix/store/without-policy.drv";
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
      dependencies = ["without-updater"];
    }
    {
      name = "without-updater";
      path = "/nix/store/without-updater.drv";
      updater = false;
      refresh = false;
      dependencies = null;
    }
    {
      name = "unavailable";
      path = null;
      updater = true;
      refresh = true;
      dependencies = null;
    }
    {
      name = "without-policy";
      path = "/nix/store/without-policy.drv";
      updater = false;
      refresh = false;
      dependencies = null;
    }
    {
      name = "absent";
      path = null;
      updater = false;
      refresh = false;
      dependencies = null;
    }
  ];
in
  assert actual == expected; true
