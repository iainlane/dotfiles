{
  inputs,
  system,
}: let
  project = fromTOML (builtins.readFile (inputs.hermes-agent + "/pyproject.toml"));
  release = builtins.match ".*__release_date__ = \"([^\"]+)\".*" (
    builtins.readFile (inputs.hermes-agent + "/hermes_cli/__init__.py")
  );
  version =
    if project.project.version != "0.0.0"
    then project.project.version
    else if release != null
    then builtins.head release
    else throw "Hermes has a placeholder version and no declared release date";
in
  inputs.hermes-agent.packages.${system}.default.override {inherit version;}
