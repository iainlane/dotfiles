{
  fetchFromGitHub,
  lib,
  upstreamPackage,
}: let
  release = "0.47.0";
  rev = "c07a6ece11be59ba223df0aa506285dc52e95de4";
  src = fetchFromGitHub {
    owner = "iainlane";
    repo = "agentsview";
    inherit rev;
    hash = "sha256-dq1KB/YdKzdifH5az8h4L7YhBpG3JVhJ11PPkJqzzbY=";
  };
in
  assert lib.assertMsg (upstreamPackage.version == release) ''
    llm-agents now provides AgentsView ${upstreamPackage.version}. Review
    iainlane/agentsview's consolidated/v0.47.0-fixes branch before updating
    pkgs/agentsview to a different release.
  '';
  # The frontend source is bound inside the upstream package, so override
  # the fetcher to build both the frontend and backend from the fork.
    (upstreamPackage.override {
      fetchFromGitHub = _: src;
    }).overrideAttrs (finalAttrs: previous: {
      inherit src;
      version = "${release}-unstable-2026-11-15";
      ldflags = [
        "-s"
        "-w"
        "-X main.version=${finalAttrs.version}"
        "-X main.commit=${rev}"
        "-X main.buildDate=1970-01-01T00:00:00Z"
      ];
      passthru =
        (previous.passthru or {})
        // {
          updateScript = null;
          maintenance = {
            source = "pin";
            reason = "The fork includes the consolidated fixes for AgentsView 0.47.0.";
          };
        };
    })
