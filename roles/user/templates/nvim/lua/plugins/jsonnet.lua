-- Enhance Jsonnet support. `jsonnet` and `jsonnetfmt` LSPs and tools are handled in
-- `lsp/mason.lua`.

return {
  {
    "iainlane/nvim-jsonnet",

    branch = "iainlane/fixes",

    dependencies = {
      "nvim-lua/plenary.nvim",
    },

    opts = {
      key_prefix = "<leader>j",

      load_dap_config = true,
      jsonnet_debugger_bin = vim.fn.exepath("jsonnet-debugger") or "jsonnet-debugger",

      window = {
        width = 0.4,
      },
    },
  },

  {
    "neovim/nvim-lspconfig",

    opts = {
      servers = {
        jsonnet_ls = {
          flags = {
            debounce_text_changes = 150,
          },
          cmd = { "jsonnet-language-server", "--lint" },
          settings = {
            formatting = {
              UseImplicitPlus = true,
            },
          },
        },
      },
    },
  },

  {
    "folke/edgy.nvim",

    optional = true,

    opts = function(_, opts)
      opts.right = opts.right or {}

      table.insert(opts.right, {
        ft = "jsonnet-output",
        title = "Jsonnet",

        size = { width = 50 },
      })
    end,
  },
}
