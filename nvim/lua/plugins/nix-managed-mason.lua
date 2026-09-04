---Normalised shape of `nix-managed-lsp.json`.
---
---@class NixManagedLspConfig
---@field mason_packages string[] Mason package names managed by Nix and excluded from Mason auto-installs.
---@field lsp_servers string[] LSP server names that should set `mason = false` in lspconfig.

---@type uv|nil
local uv = vim.uv or vim.loop

---Create a safe default config when the JSON file is missing or invalid.
---@return NixManagedLspConfig
local function empty_config()
  return { mason_packages = {}, lsp_servers = {} }
end

---Read a file from disk and return its contents.
---
---@param path string
---@return string|nil data File content, or `nil` when unavailable.
local function read_file(path)
  if not uv then
    return nil
  end

  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end

  local fd = uv.fs_open(path, "r", 0)
  if not fd then
    return nil
  end

  local ok, data = pcall(uv.fs_read, fd, stat.size, 0)
  uv.fs_close(fd)
  if not ok or type(data) ~= "string" or data == "" then
    return nil
  end

  return data
end

---Load and validate Nix-managed LSP data from Neovim's state directory.
---
---@return NixManagedLspConfig
local function load_nix_managed()
  local path = vim.fn.stdpath("state") .. "/nix-managed-lsp.json"
  local data = read_file(path)
  if not data then
    return empty_config()
  end

  local ok, decoded = pcall(vim.json.decode, data)
  if not ok or type(decoded) ~= "table" then
    return empty_config()
  end

  return {
    mason_packages = type(decoded.mason_packages) == "table" and decoded.mason_packages or {},
    lsp_servers = type(decoded.lsp_servers) == "table" and decoded.lsp_servers or {},
  }
end

---Convert a list of strings into a set for O(1) membership checks.
---
---@param list string[]
---@return table<string, true> set
local function to_set(list)
  ---@type table<string, true>
  local set = {}
  for _, value in ipairs(list) do
    set[value] = true
  end
  return set
end

---Build lspconfig server options that force each server off Mason management.
---
---@param servers string[]
---@return table<string, { mason: boolean }> opts
local function to_lsp_server_opts(servers)
  ---@type table<string, { mason: boolean }>
  local opts = {}
  for _, server in ipairs(servers) do
    opts[server] = { mason = false }
  end
  return opts
end

local nix_managed = load_nix_managed()
local nix_managed_mason = to_set(nix_managed.mason_packages)
local lsp_servers = to_lsp_server_opts(nix_managed.lsp_servers)

---@type LazySpec
local spec = {
  {
    "mason-org/mason.nvim",
    ---Filter Mason auto-install list to exclude packages provided by Nix.
    ---@param _ LazyPlugin
    ---@param opts MasonSettings|{ ensure_installed: string[] }
    opts = function(_, opts)
      opts.ensure_installed = vim.tbl_filter(function(pkg)
        return not nix_managed_mason[pkg]
      end, opts.ensure_installed or {})
    end,
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = lsp_servers,
    },
  },
}

return spec
