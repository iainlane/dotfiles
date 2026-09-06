--- Construct our preferred colours from some built-in highlight groups, taking
--- only their foreground attributes: the window supplies the background.
local function setup_incline_highlights()
  local match_paren_hl = vim.api.nvim_get_hl(0, { name = "MatchParen" })
  local bold_hl = vim.api.nvim_get_hl(0, { name = "Bold" })

  vim.api.nvim_set_hl(0, "InclineModified", {
    force = true,

    fg = match_paren_hl.fg,
    bold = true,
  })

  vim.api.nvim_set_hl(0, "InclineFilename", {
    force = true,

    fg = bold_hl.fg,
    bold = true,
  })

  vim.api.nvim_set_hl(0, "InclineDirectory", {
    force = true,
  })
end

--- Pretty print a path for the incline.nvim statusline. The path is shown
--- relative to the working directory, with the home directory as `~`, or in
--- full when it is under neither. If LazyVim's root module is loaded and the
--- file is under the project root, the path relative to that root is used
--- instead, calculated from the file's own name. It is split into
--- components, and when there are more than 3 (`len`) the middle ones are
--- replaced with an ellipsis. The last component, the filename, is rendered
--- with the `Bold` highlight group when the buffer is unmodified and with
--- `MatchParen` when it is, to match LazyVim's `lualine` appearance.
---@param buf integer The buffer number
---@return table # A table of components to be displayed in the window statusline
local function incline_pretty_path(buf)
  local filename = vim.api.nvim_buf_get_name(buf)

  -- Skip for unnamed buffers
  if filename == "" then
    return { { "[no name]" } }
  end

  local modified = vim.bo[buf].modified
  local display_path = vim.fn.fnamemodify(filename, ":~:.")

  -- See if we can make it relative to the LazyVim project root.
  if package.loaded["lazyvim.util.root"] then
    local root = require("lazyvim.util.root").get()

    if root then
      display_path = vim.fs.relpath(root, filename) or display_path
    end
  end

  -- What follows is mostly borrowed from LazyVim's `pretty_path` function.
  -- https://github.com/LazyVim/LazyVim/blob/ec5981dfb1222c3bf246d9bcaa713d5cfa486fbd/lua/lazyvim/util/lualine.lua#L82

  local parts = vim.split(display_path, "[\\/]")

  -- If the path has more than `len` components, replace the middle ones with
  -- an ellipsis.
  local len = 3
  if #parts > len then
    parts = { parts[1], "…", unpack(parts, #parts - len + 2, #parts) }
  end

  local modified_hl = "InclineModified"
  local filename_hl = "InclineFilename"
  local directory_hl = "InclineDirectory"

  -- Get the OS-specific path separator
  local sep = package.config:sub(1, 1)

  local result = {}

  -- The directory components, with a separator between them and one after
  -- the last.
  if #parts > 1 then
    for i = 1, #parts - 1 do
      if i > 1 then
        table.insert(result, { sep, group = directory_hl })
      end

      table.insert(result, { parts[i], group = directory_hl })
    end

    table.insert(result, { sep, group = directory_hl })
  end

  table.insert(result, { parts[#parts], group = modified and modified_hl or filename_hl })

  return result
end

return {
  {
    "b0o/incline.nvim",
    event = "BufReadPre",

    dependencies = {
      "nvim-tree/nvim-web-devicons",
    },

    opts = {
      -- <icon><space><path>
      -- path is abbreviated and coloured in `incline_pretty_path()`
      render = function(props)
        local devicons = require("nvim-web-devicons")
        local icon, icon_hl = devicons.get_icon_by_filetype(vim.bo[props.buf].filetype, { default = true })

        local result = {
          { icon, group = icon_hl },
          { " " },
        }

        local path_components = incline_pretty_path(props.buf)
        for _, component in ipairs(path_components) do
          table.insert(result, component)
        end

        return result
      end,

      window = {
        margin = { horizontal = 0, vertical = 0 },
        padding = 1,
      },
    },

    config = function(_, opts)
      setup_incline_highlights()

      -- Update colours when colorscheme changes
      vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("InclineHighlightRefresh", { clear = true }),
        callback = function()
          setup_incline_highlights()
        end,
      })

      require("incline").setup(opts)
    end,
  },
}
