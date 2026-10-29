{
  lib,
  fetchPypi,
  gitMinimal,
  pythonPackages,
  updaters,
}:
pythonPackages.buildPythonApplication (finalAttrs: {
  pname = "mcp-server-git";
  version = "2026.10.28";
  pyproject = true;

  src = fetchPypi {
    pname = "mcp_server_git";
    inherit (finalAttrs) version;
    hash = "sha256-sCy83t2CklFrccMIIQWgm9lH0MJ3+4vrJC58NCfEVb8=";
  };

  build-system = [pythonPackages.hatchling];
  dependencies = with pythonPackages; [click gitpython mcp pydantic];
  nativeCheckInputs = with pythonPackages; [gitMinimal pytestCheckHook pytest-asyncio pytest-cov];
  pythonImportsCheck = ["mcp_server_git"];

  postPatch = ''
    substituteInPlace tests/test_entrypoints.py \
      --replace-fail 'path=str(Path(sys.executable).parent)' "path=\"$out/bin\""
    substituteInPlace tests/test_protocol.py \
      --replace-fail '"cmdline: git add -- nope.txt"' \
        'f"cmdline: {git.Git.GIT_PYTHON_GIT_EXECUTABLE} add -- nope.txt"'
  '';

  passthru.updateScript = updaters.mkNixUpdateUpdater {attr = "mcp-server-git";};

  meta = {
    description = "MCP server for Git repositories";
    homepage = "https://github.com/modelcontextprotocol/servers/tree/main/src/git";
    license = lib.licenses.mit;
    mainProgram = "mcp-server-git";
  };
})
