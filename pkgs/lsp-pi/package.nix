# Runs LSP diagnostics on touched files after agent runs end, and adds
# on-demand symbol/reference tools. Reuses the language servers that
# `mcp.wrapWithTools` puts on PATH.
#
# To update: nix run .#update-lsp-pi
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "lsp-pi";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "LSP extension for pi-coding-agent - provides language server tool and diagnostics feedback for Dart/Flutter, TypeScript, Vue, Svelte, Python, Go, Kotlin, Swift, Rust";
}
