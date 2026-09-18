{
  fetchPypi,
  lib,
  pythonPackages,
  updaters,
}:
pythonPackages.buildPythonPackage (finalAttrs: {
  pname = "agentmail";
  version = "2.0.1";
  pyproject = true;

  src = fetchPypi {
    inherit (finalAttrs) pname version;
    hash = "sha256-nbTFM2IXZ9515BuO13h3oySNXXOMhfRoX12LT05jTY4=";
  };

  # agentmail 2.0.1 accidentally places project metadata inside
  # [build-system], which causes pypa/build to reject pyproject.toml.
  postPatch = ''
    sed -E -i '/^\[build-system\]/,$ {
      /^(description|authors|keywords|license|homepage)[[:space:]]*=/d
    }' pyproject.toml
  '';

  build-system = with pythonPackages; [
    poetry-core
  ];

  dependencies = with pythonPackages; [
    httpx
    pydantic
    pydantic-core
    typing-extensions
    websockets
  ];

  pythonImportsCheck = [
    "agentmail"
  ];

  passthru.updateScript = updaters.mkNixUpdateUpdater {
    attr = "agentmail";
  };

  meta = {
    description = "Python client for the AgentMail API";
    homepage = "https://github.com/agentmail-to/agentmail-python";
    license = lib.licenses.mit;
  };
})
