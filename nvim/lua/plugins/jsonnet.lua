-- Enhance Jsonnet support. Mason/LSP integration is configured via
-- `plugins/nix-managed-mason.lua` and `nix-managed-lsp.json`.

---Answers from `is_tanka_project`, keyed by root directory. The probe runs a
---subprocess and waits for it, which blocks the editor, and the language
---server is started once per workspace and per restart.
---@type table<string, boolean>
local tanka_projects = {}

---Whether `tk` can resolve a jpath for `fname`, which it can do only inside a
---Tanka project. Tanka is not packaged here, so the caller checks for `tk`
---first; `vim.system` raises when the executable is missing.
---@param fname string Absolute path of the file the server is starting for
---@param root_dir string Directory to run `tk` in
---@return boolean
local function is_tanka_project(fname, root_dir)
  if tanka_projects[root_dir] == nil then
    local ok, result = pcall(function()
      return vim.system({ "tk", "tool", "jpath", fname }, { cwd = root_dir, text = true }):wait(2000)
    end)
    tanka_projects[root_dir] = ok and result.code == 0
  end

  return tanka_projects[root_dir]
end

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
      servers = {
        jsonnet_ls = {
          ---@param dispatchers vim.lsp.rpc.Dispatchers
          ---@param config vim.lsp.ClientConfig
          ---@return vim.lsp.rpc.PublicClient
          cmd = function(dispatchers, config)
            local cmd_args = { "jsonnet-language-server", "--lint" }

            local fname = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
            local probe = vim.fn.executable("tk") == 1 and config.root_dir ~= nil and fname ~= ""

            if probe and is_tanka_project(fname, config.root_dir) then
              table.insert(cmd_args, "--tanka")
            end

            return vim.lsp.rpc.start(cmd_args, dispatchers, {})
          end,

          filetypes = { "jsonnet", "libsonnet" },
          flags = { debounce_text_changes = 150 },
          settings = { formatting = { UseImplicitPlus = true } },
          root_markers = { "jsonnetfile.json", ".git" },
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
