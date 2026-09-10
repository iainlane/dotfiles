{
  agentmail,
  hermesAgent,
  hermesSource,
  lib,
  pkgs,
  pythonPackages,
}:
pythonPackages.buildPythonPackage {
  pname = "hermes-inbox";
  inherit ((lib.importTOML ./pyproject.toml).project) version;
  src = lib.fileset.toSource {
    root = ./.;
    fileset =
      lib.fileset.fileFilter (
        file:
          file.type
          == "regular"
          && lib.any file.hasExt ["py" "toml" "yaml"]
      )
      ./.;
  };
  pyproject = true;
  build-system = [pythonPackages.setuptools];
  dependencies = [
    agentmail
    pythonPackages.beautifulsoup4
    pythonPackages.markdownify
    pythonPackages.pydantic
  ];
  nativeCheckInputs = [
    pkgs.basedpyright
    pythonPackages.pytest
    pkgs.ruff
  ];
  preCheck = ''
    ruff check hermes_inbox plugin tests
    ruff format --check hermes_inbox plugin tests
    basedpyright \
      --pythonpath ${hermesAgent.hermesVenv}/bin/python3 \
      hermes_inbox plugin tests
    ${hermesAgent.hermesVenv}/bin/python3 -c \
      "import agentmail, bs4, markdownify, pydantic; import hermes_inbox"
  '';
  checkPhase = ''
    runHook preCheck

    HERMES_SOURCE=${hermesSource} \
      ${hermesAgent.hermesVenv}/bin/python3 -m pytest \
      tests

    runHook postCheck
  '';
  pythonImportsCheck = ["hermes_inbox"];
  passthru.updateScript = null;
  postInstall = ''
    mkdir -p "$out/share/hermes-inbox-plugin"
    cp plugin/__init__.py "$out/share/hermes-inbox-plugin/__init__.py"
    cp plugin.yaml "$out/share/hermes-inbox-plugin/plugin.yaml"
  '';
}
