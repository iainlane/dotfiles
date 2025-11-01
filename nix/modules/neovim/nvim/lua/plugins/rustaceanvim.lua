-- Use bacon-ls for Rust diagnostics instead of rust-analyzer
-- bacon and bacon-ls are provided by nix extraPackages
vim.g.lazyvim_rust_diagnostics = "bacon-ls"

return {
  -- Don't install bacon or bacon-ls via mason since they're provided by nix
  {
    "mason-org/mason.nvim",

    opts = function(_, opts)
      local nix_provided = { "bacon", "bacon-ls" }
      opts.ensure_installed = vim.tbl_filter(function(pkg)
        return not vim.tbl_contains(nix_provided, pkg)
      end, opts.ensure_installed or {})
    end,
  },
}
