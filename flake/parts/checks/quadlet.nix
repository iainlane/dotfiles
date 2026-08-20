{lib, ...}: let
  quadlet = import ../../../lib/quadlet.nix {inherit lib;};

  throws = value: !(builtins.tryEval (builtins.deepSeq value true)).success;

  assertions = [
    {
      name = "a Quadlet-managed volume renders its unit reference";
      pass =
        quadlet.mount {
          source.quadletVolume = "state";
          target = "/var/lib/service";
          ownership = "idmap";
        }
        == "state.volume:/var/lib/service:idmap";
    }
    {
      name = "a Podman named volume renders its runtime name";
      pass =
        quadlet.mount {
          source.podmanVolume = "state";
          target = "/var/lib/service";
        }
        == "state:/var/lib/service";
    }
    {
      name = "a bind mount renders its source path and access mode";
      pass =
        quadlet.mount {
          source.bind = "/nix/store/config";
          target = "/etc/service";
          readOnly = true;
        }
        == "/nix/store/config:/etc/service:ro";
    }
    {
      name = "mount options render in a stable order";
      pass =
        quadlet.mount {
          source.bind = "/run/config";
          target = "/etc/service";
          ownership = "idmap";
          readOnly = true;
        }
        == "/run/config:/etc/service:idmap,ro";
    }
    {
      name = "a path bind preserves Nix's store-path context";
      pass =
        quadlet.mount {
          source.bind = ../../../profiles/hermes/soul.md;
          target = "/soul.md";
          readOnly = true;
        }
        == "${../../../profiles/hermes/soul.md}:/soul.md:ro";
    }
    {
      name = "chown ownership renders Podman's U option";
      pass =
        quadlet.mount {
          source.quadletVolume = "database";
          target = "/var/lib/database";
          ownership = "chown";
        }
        == "database.volume:/var/lib/database:U";
    }
    {
      name = "mounts renders a list of typed mounts";
      pass =
        quadlet.mounts [
          {
            source.podmanVolume = "one";
            target = "/one";
          }
          {
            source.bind = "/source";
            target = "/two";
            readOnly = true;
          }
        ]
        == [
          "one:/one"
          "/source:/two:ro"
        ];
    }
    {
      name = "the schema rejects an unknown ownership mode";
      pass = throws (quadlet.mount {
        source.quadletVolume = "state";
        target = "/data";
        ownership = "shift";
      });
    }
    {
      name = "the schema rejects more than one source variant";
      pass = throws (quadlet.mount {
        source = {
          bind = "/source";
          podmanVolume = "state";
        };
        target = "/data";
      });
    }
    {
      name = "the schema rejects a relative container path";
      pass = throws (quadlet.mount {
        source.bind = "/source";
        target = "data";
      });
    }
    {
      name = "the schema rejects unmodelled mount options";
      pass = throws (quadlet.mount {
        source.bind = "/source";
        target = "/data";
        options = ["ro"];
      });
    }
    {
      name = "an auto user namespace rejects every kind of named volume without idmap";
      pass =
        quadlet.autoUsernsVolumesWithoutIdmap {
          dex.containerConfig = {
            userns = "auto";
            volumes = [
              "dex-state.volume:/var/lib/dex"
              "external-state:/var/lib/external"
              "/nix/store/config:/etc/dex:ro"
            ];
          };
        }
        == [
          {
            container = "dex";
            mount = "dex-state.volume:/var/lib/dex";
          }
          {
            container = "dex";
            mount = "external-state:/var/lib/external";
          }
        ];
    }
    {
      name = "typed ID-mapped mounts satisfy the auto-userns contract";
      pass =
        quadlet.autoUsernsVolumesWithoutIdmap {
          dex.containerConfig = {
            userns = "auto:size=65536";
            volumes = quadlet.mounts [
              {
                source.quadletVolume = "dex-state";
                target = "/var/lib/dex";
                ownership = "idmap";
              }
              {
                source.podmanVolume = "external-state";
                target = "/var/lib/external";
                ownership = "idmap";
              }
            ];
          };
        }
        == [];
    }
    {
      name = "the contract ignores bind mounts and other user namespaces";
      pass =
        quadlet.autoUsernsVolumesWithoutIdmap {
          auto.containerConfig = {
            userns = "auto";
            volumes = ["/nix/store/config:/etc/service:ro"];
          };
          fixed.containerConfig = {
            userns = "keep-id";
            volumes = ["state.volume:/var/lib/service"];
          };
        }
        == [];
    }
  ];

  failures = lib.filter (assertion: !assertion.pass) assertions;
  report = lib.concatMapStringsSep "\n" (assertion: "  x ${assertion.name}") failures;
in {
  perSystem = {pkgs, ...}: {
    checks.quadlet-contracts =
      if failures == []
      then pkgs.runCommandLocal "quadlet-contracts" {} "touch $out"
      else throw "quadlet contract checks failed:\n${report}";
  };
}
