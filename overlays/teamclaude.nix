_: _: prev: {
  teamclaude = assert prev.lib.assertMsg (prev.teamclaude.version == "1.1.26") ''
    TeamClaude ${prev.teamclaude.version} has changed. Review upstream PR #621
    and remove or refresh overlays/teamclaude.nix.
  '';
    prev.teamclaude.overrideAttrs {
      version = "1.1.26-unstable-2026-10-30";
      src = prev.fetchFromGitHub {
        owner = "iainlane";
        repo = "teamclaude";
        rev = "654fd97303f927078cafafdbf980f0c11c5af61e";
        hash = "sha256-aH+RFzSbS5boQlHv1L6b4Jn1Yx4Sy9oCT7RCWhTOTn8=";
      };
    };
}
