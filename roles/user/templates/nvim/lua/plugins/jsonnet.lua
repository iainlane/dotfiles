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
    name = "jsonnet_ls-config",
    dir = vim.fn.stdpath("config"),
    config = function()
      ---Run a command and return true if it exits with success
      ---@param args string[] Command and arguments to execute
      ---@param cwd string|nil Working directory for the command
      ---@return boolean ok True if command exits with code 0, false otherwise
      local function cmd_ok(args, cwd)
        local res = vim.system(args, { cwd = cwd }):wait()
        return res and res.code == 0
      end

      vim.lsp.config("jsonnet_ls", {
        ---@param dispatchers vim.lsp.rpc.Dispatchers
        ---@param config vim.lsp.ClientConfig
        ---@return vim.lsp.rpc.PublicClient
        cmd = function(dispatchers, config)
          ---@type string[]
          local cmd_args = { "jsonnet-language-server", "--lint" }

          if config.root_dir then
            local bufnr = vim.api.nvim_get_current_buf()
            local fname = vim.api.nvim_buf_get_name(bufnr)

            if fname ~= "" and cmd_ok({ "tk", "tool", "jpath", fname }, config.root_dir) then
              table.insert(cmd_args, "--tanka")
            end
          end

          return vim.lsp.rpc.start(cmd_args, dispatchers, {})
        end,

        filetypes = { "jsonnet", "libsonnet" },
        flags = { debounce_text_changes = 150 },
        settings = { formatting = { UseImplicitPlus = true } },
        root_markers = { "jsonnetfile.json", ".git" },
      })

      vim.lsp.enable("jsonnet_ls")
    end,
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
