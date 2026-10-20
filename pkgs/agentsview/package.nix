# AgentsView from a commit on `main`, for kenn-io/agentsview#2255 and #2278.
# Both fix PostgreSQL pushes from Hermes, and llm-agents packages 0.45.0, which
# has neither. Evaluation fails once llm-agents moves to another release.
{
  agentsview,
  fetchFromGitHub,
  fetchNpmDeps,
  lib,
}: let
  release = "0.45.0";
  rev = "d0540577f8d735d3107ee26445b2791875562979";

  src = fetchFromGitHub {
    owner = "kenn-io";
    repo = "agentsview";
    inherit rev;
    hash = "sha256-JMRc8g4kaeqnHkDt6rAvVlj9Xc8ZYE9buH2e9bDEBDE=";
  };
in
  assert lib.assertMsg (agentsview.version == release) ''
    llm-agents now provides agentsview ${agentsview.version}. Check that it
    includes kenn-io/agentsview#2255 and #2278, then remove pkgs/agentsview and
    use the llm-agents package.
  '';
  # Upstream's derivation builds the frontend from a source bound in a `let`,
  # which `overrideAttrs` cannot reach. Overriding the fetchers gives the
  # frontend the same source as the Go module.
    (agentsview.override {
      fetchFromGitHub = _: src;

      fetchNpmDeps = args:
        fetchNpmDeps (args
          // {
            hash = "sha256-FVUzcTbXurndDePaxz3+qhlXs7nya8I6YXUn7KUKD8c=";
          });
    }).overrideAttrs (finalAttrs: _prevAttrs: {
      inherit src;
      version = "${release}-unstable-2026-10-19";
      vendorHash = "sha256-20Wd41Ecb+x57SsqshqzthbLhPKVVCP8q264K9VlfXI=";

      ldflags = [
        "-s"
        "-w"
        "-X main.version=${finalAttrs.version}"
        "-X main.commit=${rev}"
        "-X main.buildDate=1970-01-01T00:00:00Z"
      ];
    })
