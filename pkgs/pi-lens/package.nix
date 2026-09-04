# To update: nix run .#update-pi-lens
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "pi-lens";
  source = ./source.json;
  npmRoot = ./npm-deps;

  # The registry tarball, not the release tag. pi-lens builds `dist/` and
  # downloads its tree-sitter grammars in a `prepare` script, both of which
  # need network access the sandbox does not have. The published tarball
  # contains the result of that script already.

  # 4.1.x imports the TypeScript compiler API at runtime but declares
  # TypeScript as a development dependency, so an install that omits the dev
  # tree leaves the extension unable to load. Resolve it as a direct
  # dependency until upstream moves it.
  npmDependencies.typescript = "7.0.2";

  # ast-grep is a Rust binary behind a Node addon, so pi-lens cannot do its
  # structural analysis without the optional dependency matching this system.
  omitOptional = false;

  description = "Real-time code feedback for pi through LSP, linters, formatters, type checking and structural analysis";
}
