{
  fetchPypi,
  lib,
  pythonPackages,
  updaters,
}:
pythonPackages.buildPythonPackage (finalAttrs: {
  pname = "agentmail";
  version = "2.0.14";
  pyproject = true;

  src = fetchPypi {
    inherit (finalAttrs) pname version;
    hash = "sha256-cd5YtZ58e8Gn31IafIXqOXevyxbwhad+6wH814ZkfSQ=";
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
