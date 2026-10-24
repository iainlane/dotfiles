{lib}: topology: let
  hosts = lib.filterAttrs (_: host:
    host.archive.enable || host.server.enable || host.publishers != {})
  topology.hosts;
in {
  hosts =
    lib.mapAttrs (host: inventory: {
      userSecretsFile =
        if inventory.archive.enable
        then inventory.archive.secretsFile
        else null;
      serverSecretsFile =
        if inventory.server.enable
        then inventory.server.secretsFile
        else null;
      publishers = lib.mapAttrs (_: publisher:
        publisher
        // {
          recipientSource = publisher.secretsFile;
          serverRecipientSource = topology.server.secretsFile;
        }) (lib.filterAttrs (_: publisher: publisher.host == host) topology.publishers);
    })
    hosts;
}
