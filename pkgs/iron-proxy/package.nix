{
  buildGoLatestModule,
  fetchFromGitHub,
  lib,
  updaters,
}:
buildGoLatestModule (finalAttrs: {
  pname = "iron-proxy";
  version = "0.56.0";
  src = fetchFromGitHub {
    owner = "paradigmxyz";
    repo = "iron-proxy";
    tag = "v${finalAttrs.version}";
    hash = "sha256-1njtrSk7wqWCZQGGpRmlb/gbVmP64Lg1wXBZKxpEol4=";
  };
  proxyVendor = true;
  vendorHash = "sha256-VmQLytOqbZi5Yht+2TmyOgm/lk/K+ikFdS/g/k8jEfg=";
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
