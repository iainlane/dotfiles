{
  buildGoLatestModule,
  fetchFromGitHub,
  lib,
  updaters,
}:
buildGoLatestModule (finalAttrs: {
  pname = "iron-proxy";
  version = "0.55.0";
  src = fetchFromGitHub {
    owner = "paradigmxyz";
    repo = "iron-proxy";
    tag = "v${finalAttrs.version}";
    hash = "sha256-OmlfAy3/Dh9YHpFad9L/GAxuQY43pz5LqNPTW0oDB4k=";
  };
  proxyVendor = true;
  vendorHash = "sha256-gD80M4P+RgHVfgy7VHjr3L6a4yoYr+QJmpx4Z5OrZQY=";
  subPackages = ["cmd/iron-proxy"];
  ldflags = ["-s" "-w"];
  checkFlags = ["-short"];
  __darwinAllowLocalNetworking = true;
  passthru = {
    updateScript = updaters.mkNixUpdateUpdater {attr = "iron-proxy";};
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
