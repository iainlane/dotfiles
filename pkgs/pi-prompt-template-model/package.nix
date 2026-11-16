# To update: nix run .#update-pi-prompt-template-model
{
  callPackage,
  jq,
}:
(callPackage ../build-support/pi-extension.nix {
  npmName = "pi-prompt-template-model";
  source = ./source.json;
  npmRoot = ./npm-deps;
  # Every minimatch 10.x release is affected by GHSA-g3hv-75wg-m249, which
  # 11.0.1 fixes.
  npmDependencies.minimatch = "^11.0.3";
  description = "Prompt template model selector extension for pi coding agent";
}).overrideAttrs (old: {
  doInstallCheck = true;
  nativeInstallCheckInputs = [jq];
  installCheckPhase = ''
    runHook preInstallCheck
    jq --exit-status '.version | split(".") | map(tonumber) >= [11, 0, 1]' \
      "$out/${old.passthru.packageRoot}/node_modules/minimatch/package.json"
    runHook postInstallCheck
  '';
})
