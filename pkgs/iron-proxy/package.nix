{
  buildGoLatestModule,
  fetchFromGitHub,
  lib,
  updaters,
}:
buildGoLatestModule (finalAttrs: {
  pname = "iron-proxy";
  version = "0.61.0";
  src = fetchFromGitHub {
    owner = "paradigmxyz";
    repo = "iron-proxy";
    tag = "v${finalAttrs.version}";
    hash = "sha256-Pggh5nK/jmzkLQPwCOfu6zJpK5pDWBbE7HdOCm7Mg0Y=";
  };
  proxyVendor = true;
  vendorHash = "sha256-NlRUbMmwcLevg6hhS3p26ZzXOy6Svya5JKuAjHXoqM0=";
  subPackages = ["cmd/iron-proxy"];
  ldflags = ["-s" "-w"];
  checkFlags = ["-short"];
  __darwinAllowLocalNetworking = true;
  passthru = {
    updateScript = updaters.mkNixUpdateUpdater {
      refresh = true;
      attr = "iron-proxy";
    };
    transformProto = "${finalAttrs.src}/proto/transform/v1/transform.proto";
  };
  meta = {
    description = "Intercepting HTTP proxy with destination policy and credential injection";
    homepage = "https://github.com/paradigmxyz/iron-proxy";
    license = lib.licenses.asl20;
    mainProgram = "iron-proxy";
    platforms = lib.platforms.unix;
  };
})
