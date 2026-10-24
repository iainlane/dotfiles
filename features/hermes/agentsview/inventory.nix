{
  hostConfig,
  config,
  lib,
  ...
}: {
  agentsview.publishers.hermes = {
    machine = lib.mkDefault "${hostConfig.name}-hermes";
    certificate = lib.mkDefault "hosts/${hostConfig.name}/agentsview-hermes.pem";
    secretsFile = lib.mkDefault config.hermes.secretsFile;
    optional = true;
  };
}
