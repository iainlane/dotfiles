-- Enhance Jsonnet support. `jsonnet` and `jsonnetfmt` LSPs and tools are handled in
-- `lsp/mason.lua`.

return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "jsonnet" } },
  },

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
      ---@type table<string, vim.lsp.Config>
      servers = {
        ---@type lsp.ConfigurationItem
        jsonnet_ls = {
          flags = { debounce_text_changes = 150 },
          cmd = { "jsonnet-language-server", "--lint" },
          settings = { formatting = { UseImplicitPlus = true } },
        },
      },

      ---@type table<string, fun(server:string, config: vim.lsp.Config):boolean?>
      setup = {
        jsonnet_ls = function(server, config)
          ---Run a command and return true if it exits with success
          ---@param args string[]  e.g. { "tk", "tool", "jpath", "/abs/file.jsonnet" }
          ---@param cwd  string|nil
          ---@return boolean ok
          local function cmd_ok(args, cwd)
            local res = vim.system(args, { cwd = cwd }):wait()
            if not res then
              return false
            end
            return res.code == 0
          end

          local bufnr = vim.api.nvim_get_current_buf()
          local file = vim.api.nvim_buf_get_name(bufnr)
          local cwd = vim.fn.getcwd()

          if file ~= "" and cmd_ok({ "tk", "tool", "jpath", file }, cwd) then
            config.cmd = { "jsonnet-language-server", "--lint", "--tanka" }
          end

          -- We want LazyVim to handle the actual lsp setup for us
          return false
        end,
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
