_: _: prev: {
  mcp-proxy =
    if prev.mcp-proxy.version == "0.13.0" && prev.lib.versionAtLeast prev.python3Packages.mcp.version "2"
    then
      prev.mcp-proxy.override {
        python3Packages = prev.python3Packages.overrideScope (_: pythonPrev: {
          mcp = pythonPrev.mcp_1;
        });
      }
    else prev.mcp-proxy;
}
