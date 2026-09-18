# To update: nix run .#update-pi-plan-mode
{callPackage}:
(callPackage ../build-support/pi-extension.nix {
  npmName = "@narumitw/pi-plan-mode";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "Pi extension that adds a Codex-like read-only /plan collaboration mode.";
}).overrideAttrs (old: {
  # `@narumitw/pi-tui-kit` declares the Pi packages as peer dependencies.
  # npm would resolve them from the registry, which the offline build cannot
  # fetch. Pi provides an extension's peers at runtime, so skip peer
  # resolution.
  npmInstallFlags = (old.npmInstallFlags or []) ++ ["--legacy-peer-deps"];
})
