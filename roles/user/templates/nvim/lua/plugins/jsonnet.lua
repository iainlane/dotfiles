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
        ---@type lspconfig.options
        jsonnet_ls = (function()
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

          ---@class JsonnetClientConfig: vim.lsp.ClientConfig
          ---@field cmd string[]

          return {
            flags = { debounce_text_changes = 150 },
            cmd = { "jsonnet-language-server", "--lint" },
            settings = { formatting = { UseImplicitPlus = true } },

            ---Run the language server with `--tanka` if we're in a Tanka
            ---project.
            ---@param new_config JsonnetClientConfig
            ---@param root_dir string
            on_new_config = function(new_config, root_dir)
              local bufnr = vim.api.nvim_get_current_buf()
              local file = vim.api.nvim_buf_get_name(bufnr)

              if not cmd_ok({ "tk", "tool", "jpath", file }, root_dir) then
                return
              end

              new_config.cmd = { "jsonnet-language-server", "--lint", "--tanka" }
            end,
          }
        end)(),
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
