-- Use bacon-ls for Rust diagnostics instead of rust-analyzer
-- bacon and bacon-ls are provided by nix extraPackages
vim.g.lazyvim_rust_diagnostics = "bacon-ls"

return {}
