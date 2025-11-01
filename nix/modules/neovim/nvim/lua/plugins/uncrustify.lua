--- Check if uncrustify is available in PATH
---@return boolean available True if uncrustify command is available
local is_uncrustify_available = function()
  return vim.fn.executable("uncrustify") == 1
end

if not is_uncrustify_available() then
  return {}
end

--- Uncrustify configuration files to search for, in order of preference
---@type string[]
local configs = { "uncrustify.cfg", ".uncrustify.cfg", ".uncrustifyrc" }

--- Map vim filetypes to uncrustify language identifiers
---@type table<string, string>
local ft_map = {
  c = "C",
  cpp = "CPP",
  d = "D",
  cs = "CS",
  java = "JAVA",
  pawn = "PAWN",
  objc = "OC",
  objcpp = "OC+",
  vala = "VALA",
}

--- Find the first uncrustify config file by searching upward from the given path
---@param path string The file path to start searching from
---@return string|nil config_path The path to the config file, or nil if not found
local find_config = function(path)
  return vim.fs.find(configs, { path = path, upward = true })[1]
end

--- Determine formatter for a buffer based on uncrustify config availability
---@param bufnr number Buffer number
---@return string[] formatters List containing "uncrustify" when uncrustify
---should be used, or else an empty list for LSP fallback, if enabled.
local formatter = function(bufnr)
  return find_config(vim.api.nvim_buf_get_name(bufnr)) and { "uncrustify" } or {}
end

--- Build formatters_by_ft table for all supported filetypes
---@type table<string, fun(bufnr: number): string[]>
local formatters_by_ft = {}
for ft in pairs(ft_map) do
  formatters_by_ft[ft] = formatter
end

--- Generate uncrustify command arguments for the current buffer
---@return string[] args Command line arguments for uncrustify
local format_args = function()
  local filename = vim.api.nvim_buf_get_name(0)
  local config_path = find_config(filename)
  local lang = ft_map[vim.bo.filetype] or "C"

  return { "-c", config_path, "-l", lang }
end

-- @type LazySpec
return {
  "stevearc/conform.nvim",
  opts = {
    formatters_by_ft = formatters_by_ft,
    formatters = {
      uncrustify = {
        args = format_args,
        stdin = true,
      },
    },
  },
}
