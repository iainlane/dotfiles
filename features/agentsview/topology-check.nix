{
  lib,
  pkgs,
  ...
}: let
  aggregate = import ./topology.nix {inherit lib;};
  inventory = name: modules:
    (lib.evalModules {
      specialArgs.hostConfig = {inherit name;};
      modules = [./inventory-schema.nix] ++ modules;
    }).config;
  fixtures = {
    workstation = inventory "workstation" [
      {
        agentsview.archive = {
          enable = true;
          publish = true;
        };
        agentsview.embeddings = "local";
      }
    ];
    work = inventory "work" [{agentsview.archive.enable = true;}];
    archive = inventory "archive" [
      {
        agentsview.server = {
          enable = true;
          domain = "archive.example";
          secretsFile = "archive/custom.yaml";
        };
      }
    ];
    bot = inventory "bot" [
      {
        agentsview.publishers.bot-hermes = {
          certificate = "hosts/bot/agentsview-hermes.pem";
          secretsFile = "bot/custom-hermes.yaml";
          optional = true;
        };
      }
    ];
  };
  publisherPair = overrides:
    inventory "pair" [
      {
        agentsview.publishers =
          lib.recursiveUpdate {
            first = {
              certificate = "hosts/pair/first.pem";
              secretsFile = "pair/first.yaml";
            };
            second = {
              certificate = "hosts/pair/second.pem";
              secretsFile = "pair/second.yaml";
            };
          }
          overrides;
      }
    ];
  topology = aggregate fixtures;
  provisioning = import ./provisioning-plan.nix {inherit lib;};
  privateFixtures = lib.mapAttrs (_: value:
    value
    // {
      systemConfig = throw "Inventory forced a system configuration";
      homeConfig = throw "Inventory forced a home configuration";
      hostResults = throw "Inventory forced host results";
      secrets = throw "Inventory forced a private source";
    })
  fixtures;
  throws = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  readiness = import ./publisher-readiness.nix;
  assertions = [
    {
      name = "Hermes identity overrides and shared secret paths use normal module priorities";
      pass = let
        host = inventory "bot" [
          {
            options.hermes.secretsFile = lib.mkOption {
              type = lib.types.str;
              default = "bot/default.yaml";
            };
          }
          ../hermes/agentsview/inventory.nix
          {
            hermes.secretsFile = "bot/shared.yaml";
            agentsview.publishers.hermes.machine = "custom-bot";
          }
        ];
      in
        host.agentsview.publishers
        == {
          hermes = {
            machine = "custom-bot";
            certificate = "hosts/bot/agentsview-hermes.pem";
            passwordFile = "agentsview-postgres/custom-bot.yaml";
            secretsFile = "bot/shared.yaml";
            optional = true;
          };
        };
    }
    {
      name = "optional server enrolment and local activation use different credential requirements";
      pass = lib.all (test: readiness test.input == test.expected) [
        {
          input = {
            optional = true;
            certificatePresent = false;
            passwordPresent = false;
          };
          expected = {
            enrol = false;
            activate = false;
          };
        }
        {
          input = {
            optional = true;
            certificatePresent = true;
            passwordPresent = false;
            keyPresent = true;
          };
          expected = {
            enrol = false;
            activate = false;
          };
        }
        {
          input = {
            optional = true;
            certificatePresent = true;
            passwordPresent = true;
          };
          expected = {
            enrol = true;
            activate = false;
          };
        }
        {
          input = {
            optional = true;
            certificatePresent = true;
            passwordPresent = true;
            keyPresent = true;
          };
          expected = {
            enrol = true;
            activate = true;
          };
        }
        {
          input = {
            optional = false;
            certificatePresent = false;
            passwordPresent = false;
          };
          expected = {
            enrol = true;
            activate = false;
          };
        }
      ];
    }
    {
      name = "provisioning destinations must be canonical relative paths";
      pass = lib.all (path: throws (inventory "fixture" [{agentsview.archive.secretsFile = path;}])) [
        "/absolute"
        "../outside"
        "nested/../outside"
        "line\nbreak"
        "./key.yaml"
        "nested/./key.yaml"
        "nested//key.yaml"
        "nested/"
        "back\\slash.yaml"
        "-key.yaml"
        "."
      ];
    }
    {
      name = "publisher identities fit PostgreSQL roles, connection URLs and certificate subjects";
      pass = lib.all (machine:
        throws (publisherPair {first.machine = machine;})) [
        ""
        "odd:role"
        "odd'role"
        "odd\"role"
        "odd/role"
        "line\nbreak"
        "white space"
        (lib.concatStrings (lib.replicate 64 "m"))
        "pg_custom"
        "postgres"
        "agentsview_dashboard"
        "agentsview_push"
        "public"
        "none"
        "."
        ".."
      ];
    }
    {
      name = "host-derived identities use the publisher identity contract";
      pass = lib.all (name:
        throws (aggregate ({inherit (fixtures) archive;}
          // {
            ${name} = inventory name [
              {
                agentsview.archive = {
                  enable = true;
                  publish = true;
                };
              }
            ];
          }))) ["odd:host" "postgres" (lib.concatStrings (lib.replicate 64 "h"))];
    }
    {
      name = "safe ASCII publisher identities retain the complete 63-byte limit";
      pass = lib.all (machine:
        (aggregate {
          inherit (fixtures) archive;
          pair = publisherPair {first.machine = machine;};
        }).publishers.${
          machine
        }.machine
        == machine) [
        (lib.concatStrings (lib.replicate 63 "m"))
        "fixture-role_1.v2"
        "_service"
        "PUBLIC"
      ];
    }
    {
      name = "publisher database passwords use separate files";
      pass = throws (aggregate {
        inherit (fixtures) archive;
        pair = publisherPair {second.passwordFile = "agentsview-postgres/first.yaml";};
      });
    }
    {
      name = "database password files cannot contain client or server credentials";
      pass = lib.all (passwordFile:
        throws (aggregate {
          inherit (fixtures) archive work;
          pair = publisherPair {first = {inherit passwordFile;};};
        })) ["pair/first.yaml" "pair/second.yaml" "work/user-agentsview.yaml" "archive/custom.yaml"];
    }
    {
      name = "server credentials remain separate from client keys and user tokens";
      pass = lib.all (secretsFile:
        throws (aggregate {
          inherit (fixtures) work;
          archive = inventory "archive" [
            {
              agentsview.server = {
                enable = true;
                domain = "archive.example";
                inherit secretsFile;
              };
            }
          ];
          pair = publisherPair {};
        })) ["pair/first.yaml" "work/user-agentsview.yaml"];
    }
    {
      name = "database endpoints must be DNS hosts without URI or TLS delimiters";
      pass = lib.all (domain:
        throws (inventory "archive" [
          {
            agentsview.server = {
              enable = true;
              inherit domain;
            };
          }
        ])) [
        ""
        "https://db.example"
        "db.example:443"
        "db.example/path"
        "db.example?query"
        "db.example#fragment"
        "db_.example"
        "-db.example"
        "db-.example"
        "db..example"
        "db.example."
        (lib.concatStrings (lib.replicate 64 "h") + ".example")
        (lib.concatStringsSep "." (lib.replicate 3 (lib.concatStrings (lib.replicate 63 "h")) ++ [(lib.concatStrings (lib.replicate 62 "h"))]))
      ];
    }
    {
      name = "DNS hosts preserve valid label and total-length boundaries";
      pass = lib.all (domain:
        (inventory "archive" [
          {
            agentsview.server = {
              enable = true;
              inherit domain;
            };
          }
        ]).agentsview.server.domain
        == domain) [
        "archive.example"
        "xn--bcher-kva.example"
        "192.0.2.1"
        (lib.concatStringsSep "." (lib.replicate 3 (lib.concatStrings (lib.replicate 63 "h")) ++ [(lib.concatStrings (lib.replicate 61 "h"))]))
      ];
    }
    {
      name = "certificate and key paths are escaped in PostgreSQL connection URLs";
      pass =
        (import ./common.nix {inherit lib;}).dsn {
          server = {
            domain = "archive.example";
            database = "agentsview";
          };
          machine = "fixture";
          password = "safe";
          certificate = "/tmp/client&root.pem";
          key = "/run/key+copy #1.pem";
        }
        == "postgres://fixture:safe@archive.example:443/agentsview?sslmode=verify-full&sslnegotiation=direct&sslrootcert=system&sslcert=%2Ftmp%2Fclient%26root.pem&sslkey=%2Frun%2Fkey%2Bcopy%20%231.pem";
    }
    {
      name = "provisioning uses declarations without runtime configuration or credential readiness";
      pass =
        provisioning (aggregate privateFixtures)
        == {
          hosts = {
            archive = {
              userSecretsFile = null;
              serverSecretsFile = "archive/custom.yaml";
              publishers = {};
            };
            work = {
              userSecretsFile = "work/user-agentsview.yaml";
              serverSecretsFile = null;
              publishers = {};
            };
            workstation = {
              userSecretsFile = "workstation/user-agentsview.yaml";
              serverSecretsFile = null;
              publishers.workstation =
                topology.publishers.workstation
                // {
                  recipientSource = "workstation/user-agentsview.yaml";
                  serverRecipientSource = "archive/custom.yaml";
                };
            };
            bot = {
              userSecretsFile = null;
              serverSecretsFile = null;
              publishers.bot-hermes =
                topology.publishers.bot-hermes
                // {
                  recipientSource = "bot/custom-hermes.yaml";
                  serverRecipientSource = "archive/custom.yaml";
                };
            };
          };
        };
    }
    {
      name = "local provisioning works before a private source or server exists";
      pass =
        provisioning (aggregate {inherit (fixtures) work;})
        == {
          hosts.work = {
            userSecretsFile = "work/user-agentsview.yaml";
            serverSecretsFile = null;
            publishers = {};
          };
        };
    }
    {
      name = "work policy changes only the user's publishing preference";
      pass = let
        host = inventory "bot" [
          {
            agentsview.archive = {
              enable = true;
              publish = lib.mkDefault true;
            };
            agentsview.publishers = fixtures.bot.agentsview.publishers;
          }
          {agentsview.archive.publish = lib.mkForce false;}
        ];
      in
        (aggregate {
          inherit (fixtures) archive;
          bot = host;
        }).publishers
        == {inherit (topology.publishers) bot-hermes;};
    }
    {
      name = "server-only hosts and all declared publishers form one topology";
      pass =
        topology
        == {
          hosts = lib.mapAttrs (_: value: value.agentsview) fixtures;
          server = {
            host = "archive";
            domain = "archive.example";
            database = "agentsview";
            secretsFile = "archive/custom.yaml";
          };
          publishers = {
            workstation = {
              host = "workstation";
              machine = "workstation";
              certificate = "hosts/workstation/agentsview.pem";
              passwordFile = "agentsview-postgres/workstation.yaml";
              secretsFile = "workstation/user-agentsview.yaml";
              optional = false;
              embeddings = "local";
            };
            bot-hermes = {
              host = "bot";
              machine = "bot-hermes";
              certificate = "hosts/bot/agentsview-hermes.pem";
              passwordFile = "agentsview-postgres/bot-hermes.yaml";
              secretsFile = "bot/custom-hermes.yaml";
              optional = true;
              embeddings = null;
            };
          };
          embeddings = true;
        };
    }
    {
      name = "local archives need no server";
      pass = (aggregate {inherit (fixtures) work;}).server == null;
    }
    {
      name = "publishers require a server";
      pass = throws (aggregate {inherit (fixtures) workstation;});
    }
    {
      name = "multiple servers are rejected";
      pass = throws (aggregate (fixtures // {second = fixtures.archive;}));
    }
    {
      name = "the server endpoint requires a domain";
      pass = throws (aggregate {archive = inventory "archive" [{agentsview.server.enable = true;}];});
    }
    {
      name = "duplicate archive identities are rejected";
      pass = throws (aggregate (fixtures // {duplicate = fixtures.bot;}));
    }
  ];
  failures = map (test: test.name) (lib.filter (test: !test.pass) assertions);
in {
  agentsview-topology = pkgs.runCommandLocal "agentsview-topology" {report = lib.concatStringsSep "\n" failures;} ''
    if [ -n "$report" ]; then printf '%s\n' "$report" >&2; exit 1; fi
    touch "$out"
  '';
}
