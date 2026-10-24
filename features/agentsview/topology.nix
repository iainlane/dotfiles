{lib}: inventories: let
  inherit (import ./common.nix {inherit lib;}) machineType;
  hosts = lib.mapAttrs (_: inventory: inventory.agentsview) inventories;
  servers = lib.filterAttrs (_: host: host.server.enable) hosts;
  serverNames = lib.attrNames servers;
  server =
    if serverNames == []
    then null
    else let
      host = lib.head serverNames;
    in {
      inherit host;
      inherit (servers.${host}.server) domain secretsFile;
      database = "agentsview";
    };
  entries = lib.concatLists (lib.mapAttrsToList (host: inventory:
    lib.optional (inventory.archive.enable && inventory.archive.publish) {
      name = host;
      value = {
        inherit host;
        machine = host;
        certificate = "hosts/${host}/agentsview.pem";
        passwordFile = "agentsview-postgres/${host}.yaml";
        secretsFile = inventory.archive.secretsFile;
        optional = false;
        inherit (inventory) embeddings;
      };
    }
    ++ lib.mapAttrsToList (_: publisher: {
      name = publisher.machine;
      value =
        publisher
        // {
          inherit host;
          embeddings = null;
        };
    })
    inventory.publishers)
  hosts);
  identities = map (entry: entry.name) entries;
  keyFiles = map (entry: entry.value.secretsFile) entries;
  passwordFiles = map (entry: entry.value.passwordFile) entries;
  userFiles = map (host: host.archive.secretsFile) (lib.attrValues (lib.filterAttrs (_: host: host.archive.enable) hosts));
  serverFiles = map (host: host.server.secretsFile) (lib.attrValues servers);
  certificates = map (entry: entry.value.certificate) entries;
  publishers = lib.listToAttrs entries;
in
  assert lib.assertMsg (lib.length serverNames <= 1) "AgentsView supports one shared database; multiple hosts declare a server.";
  assert lib.assertMsg (server == null || server.domain != null) "The AgentsView server must declare its database domain.";
  assert lib.assertMsg (entries == [] || server != null) "AgentsView publishers require a shared database server.";
  assert lib.assertMsg (lib.all machineType.check identities) "AgentsView machine identities must be unreserved ASCII PostgreSQL roles of at most 63 bytes, without connection-URL or certificate-subject delimiters.";
  assert lib.assertMsg (lib.length passwordFiles == lib.length (lib.unique passwordFiles)) "AgentsView publishers must use separate database password files.";
  assert lib.assertMsg (lib.intersectLists passwordFiles (keyFiles ++ userFiles ++ serverFiles) == []) "AgentsView database password files must be separate from client and server credential files.";
  assert lib.assertMsg (lib.intersectLists serverFiles (keyFiles ++ userFiles) == []) "AgentsView server credentials must be separate from client keys and user tokens.";
  assert lib.assertMsg (lib.length identities == lib.length (lib.unique identities)) "AgentsView publishers must have distinct machine identities.";
  assert lib.assertMsg (lib.length keyFiles == lib.length (lib.unique keyFiles)) "AgentsView publishers must use separate client-key files.";
  assert lib.assertMsg (lib.length certificates == lib.length (lib.unique certificates)) "AgentsView publishers must use separate certificates."; {
    inherit hosts server publishers;
    embeddings = lib.any (publisher: publisher.embeddings != null) (lib.attrValues publishers);
  }
