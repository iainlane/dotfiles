{
  fetchurl,
  lib,
  pythonPackages,
  updaters,
}:
pythonPackages.buildPythonPackage rec {
  pname = "agentmail";
  version = "0.5.10";
  format = "wheel";

  src = fetchurl {
    url = "https://files.pythonhosted.org/packages/15/ac/21b775ce14079bfc3f2eefb3238262bcccdb7eec21a266974afc75915f54/agentmail-${version}-py3-none-any.whl";
    hash = "sha256-UjPo2eGcD+x/JTmlKAjbh0b0R07ONtOajIjo1ox8VJE=";
  };

  dependencies = with pythonPackages; [
    httpx
    pydantic
    pydantic-core
    typing-extensions
    websockets
  ];

  pythonImportsCheck = ["agentmail"];

  passthru.updateScript = updaters.mkNixUpdateUpdater {attr = "agentmail";};

  meta = {
    description = "Python client for the AgentMail API";
    homepage = "https://github.com/agentmail-to/agentmail-python";
    license = lib.licenses.mit;
  };
}
