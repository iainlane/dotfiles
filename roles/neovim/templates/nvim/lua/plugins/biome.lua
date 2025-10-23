--- 1. Don't run `prettier` when we're in a Biome project - they'll conflict.
--- 2. Use `biome-check` instead of `biome`. This will additionally run linting,
---    import sorting and rules like Tailwind CSS class sorting.

---@alias condition fun(self: conform.JobFormatterConfig, ctx: conform.Context): boolean
---@alias formatters_by_ft table<string, conform.FiletypeFormatter>

---@param prettier_condition condition?
---@return condition
local function biome_condition(prettier_condition)
  return function(self, ctx)
    local run = prettier_condition and prettier_condition(self, ctx)

    if not run then
      return false
    end

    local util = require("conform.util")
    local cfg = util.root_file({
      "biome.json",
      "biome.jsonc",
    })(self, ctx)

    return cfg == nil
  end
end

--- Replaces all occurrences of a formatter name in a formatter list. Handles
--- both string formatters ("biome") and table formatters ({ "biome", opts...
--- }).
---@param formatters conform.FiletypeFormatterInternal List of formatters
---@param old_name string The formatter name to replace
---@param new_name string The new formatter name
local function replace_in_formatter_list(formatters, old_name, new_name)
  for i, formatter in ipairs(formatters) do
    if formatter == old_name then
      formatters[i] = new_name
    elseif type(formatter) == "table" and formatter[1] == old_name then
      formatter[1] = new_name
    end
  end
end

--- Replaces a formatter name in a conform.nvim formatters_by_ft configuration.
--- Handles both static configurations and dynamic function configurations per
--- filetype.
---@param formatters_by_ft formatters_by_ft? The formatters_by_ft configuration
---@param old_name string The formatter name to replace
---@param new_name string The new formatter name
---@return formatters_by_ft? The modified configuration
local function replace_formatter(formatters_by_ft, old_name, new_name)
  if not formatters_by_ft then
    return formatters_by_ft
  end

  for filetype, formatter_config in pairs(formatters_by_ft) do
    if type(formatter_config) == "function" then
      -- Wrap the function to modify its return value
      formatters_by_ft[filetype] = function(bufnr)
        local result = formatter_config(bufnr)
        replace_in_formatter_list(result, old_name, new_name)
        return result
      end
    else
      -- Modify the formatter list directly
      replace_in_formatter_list(formatter_config, old_name, new_name)
    end
  end

  return formatters_by_ft
end

return {
  {
    "stevearc/conform.nvim",
    optional = true,

    ---@param opts conform.setupOpts
    opts = function(_, opts)
      opts.formatters = opts.formatters or {}

      local prettier_formatter = opts.formatters.prettier or {}

      if not prettier_formatter then
        return opts
      end

      -- is it a function? if so, replace inside there
      if type(prettier_formatter) == "function" then
        prettier_formatter = function(bufnr)
          local config = prettier_formatter(bufnr)
          local condition = config and config.condition

          return vim.tbl_deep_extend("force", config, {
            condition = biome_condition(condition),
          })
        end

        opts.formatters.prettier = prettier_formatter

        return opts
      end

      opts.formatters.prettier = vim.tbl_deep_extend("force", prettier_formatter, {
        condition = biome_condition(prettier_formatter.condition),
      })

      -- Check for `biome` formatters and replace them with `biome-check`
      opts.formatters_by_ft = replace_formatter(opts.formatters_by_ft, "biome", "biome-check")
    end,
  },
}
