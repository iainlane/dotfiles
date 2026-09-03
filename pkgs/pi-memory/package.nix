# Persistent cross-session memory for preferences, corrections, project
# patterns, and tool habits. It stores data locally and can be curated through
# its memory tools and /memory-consolidate command.
#
# To update: nix run .#update-pi-memory
{
  callPackage,
  pkg-config,
  python3,
  vips,
}:
callPackage ../build-support/pi-extension.nix {
  npmName = "@samfp/pi-memory";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "Persistent memory for pi — learns corrections, preferences, and patterns from sessions and injects them into future conversations.";

  # From 1.5.0 the extension computes embeddings locally through
  # @xenova/transformers, which depends on sharp. sharp's install script
  # downloads a prebuilt libvips, and the build sandbox has no network. When
  # pkg-config reports a libvips at least as new as sharp's `config.libvips`,
  # that script exits instead, and sharp compiles its addon against the libvips
  # it found, so give the build nixpkgs' vips and the node-gyp toolchain.
  nativeBuildInputs = [pkg-config python3];
  buildInputs = [vips];
}
