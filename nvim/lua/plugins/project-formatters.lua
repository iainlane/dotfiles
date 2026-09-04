--- Prefer a project's own formatter over prettier:
---
--- 1. In a Biome project (`biome.json`), run `biome-check`. It formats and
---    additionally applies lint fixes, import sorting and rules such as
---    Tailwind CSS class sorting.
--- 2. In a Deno project (`deno.json`), run `deno fmt`, so that saving a file
---    agrees with `deno fmt --check`.
---
--- Prettier is only skipped for the filetypes the project formatter handles;
--- other filetypes keep using it.

---@alias condition fun(self: conform.JobFormatterConfig, ctx: conform.Context): boolean
---@alias formatters_by_ft table<string, conform.FiletypeFormatter>

---@class ProjectFormatter A formatter that takes over from prettier inside
--- projects configured for it.
---@field formatter string The `conform.nvim` formatter name.
---@field config_files string[] Files that identify the project type when one
--- is found above the buffer.
---@field register boolean? Whether to register the formatter for all
--- filetypes (`formatters_by_ft["*"]`). Nil when something else already
--- registers it.
---@field filetype_condition condition? Restricts the formatter to the
--- filetypes it can handle. Needed with `register`, which would otherwise run
--- the formatter on every filetype.

---@type ProjectFormatter[]
local project_formatters = {
  {
    -- LazyVim's Biome extra registers `biome-check` for the filetypes Biome
    -- supports.
    formatter = "biome-check",
    config_files = { "biome.json", "biome.jsonc" },
  },
  {
    formatter = "deno_fmt",
    config_files = { "deno.json", "deno.jsonc" },
    register = true,
    -- Conform's `deno_fmt` builtin guards its filetypes in a `cond` field
    -- that conform never reads. Call it ourselves to reuse the builtin's
    -- filetype map. If upstream renames the field to `condition`, conform
    -- will enforce it itself, so a missing `cond` passes.
    filetype_condition = function(self, ctx)
      local cond = require("conform.formatters.deno_fmt").cond

      return cond == nil or cond(self, ctx)
    end,
  },
}

--- Returns a condition that passes when the buffer is inside a project
--- containing one of `config_files`.
---
---@param config_files string[]
---@return condition
local function in_project(config_files)
  return function(self, ctx)
    return require("conform.util").root_file(config_files)(self, ctx) ~= nil
  end
end

--- Extends prettier's condition so prettier does not run where a project
--- formatter takes over. A project formatter takes over when it is configured
--- for the buffer and would run on it: its own condition limits it to its
--- project and to the filetypes it handles.
---
---@param original condition?
---@return condition
local function without_project_formatters(original)
  return function(self, ctx)
    local conform = require("conform")
    local configured = conform.list_formatters_for_buffer(ctx.buf)

    for _, project in ipairs(project_formatters) do
      if
        vim.tbl_contains(configured, project.formatter)
        and conform.get_formatter_info(project.formatter, ctx.buf).available
      then
        return false
      end
    end

    return original == nil or original(self, ctx)
  end
end

--- Adds a formatter to the end of a `formatters_by_ft` entry. Handles both
--- static lists and dynamic function configurations. The key is a filetype or
--- one of conform's special keys, such as `"*"` for all filetypes.
---
---@param formatters_by_ft formatters_by_ft
---@param key string
---@param name string
local function append_formatter(formatters_by_ft, key, name)
  local existing = formatters_by_ft[key]

  if existing == nil then
    formatters_by_ft[key] = { name }
    return
  end

  if type(existing) == "function" then
    formatters_by_ft[key] = function(bufnr)
      local result = existing(bufnr) or {}
      table.insert(result, name)

      return result
    end
    return
  end

  table.insert(existing, name)
end

return {
  {
    "stevearc/conform.nvim",
    optional = true,

    ---@param opts conform.setupOpts
    opts = function(_, opts)
      local util = require("conform.util")

      opts.formatters = opts.formatters or {}
      opts.formatters_by_ft = opts.formatters_by_ft or {}

      for _, project in ipairs(project_formatters) do
        local in_this_project = in_project(project.config_files)
        local filetype_condition = project.filetype_condition

        ---@type condition
        local condition = function(self, ctx)
          if filetype_condition and not filetype_condition(self, ctx) then
            return false
          end

          return in_this_project(self, ctx)
        end

        -- Run the project formatter only inside its project, from the project
        -- root so the tool finds its configuration.
        opts.formatters[project.formatter] = vim.tbl_deep_extend("force", opts.formatters[project.formatter] or {}, {
          condition = condition,
          cwd = util.root_file(project.config_files),
        })

        if project.register then
          append_formatter(opts.formatters_by_ft, "*", project.formatter)
        end
      end

      local prettier = opts.formatters.prettier

      if type(prettier) == "function" then
        opts.formatters.prettier = function(bufnr)
          local config = prettier(bufnr) or {}
          config.condition = without_project_formatters(config.condition)

          return config
        end
      else
        local config = prettier or {}
        config.condition = without_project_formatters(config.condition)
        opts.formatters.prettier = config
      end
    end,
  },
}
