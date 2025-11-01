local Path = require("plenary.path")

--- Construct our preferred colours by modifying some built-in highlight groups,
--- taking selected attributes from them. In particular, we don't want a
--- background as our window has one already.
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

--- Pretty print a path for the incline.nvim statusline. First, the path is made
--- relative to the root directory if possible (if it is under it). If not, it's
--- made relative to the home directory, represented as a `~`. Otherwise, the
--- full path is used. The path is then split up into compnents. If there are
--- more than 3 (`len`) components, the middle ones are elided and replaced with
--- an ellipsis. The last one - the filename - is rendered using the `Bold`
--- highlight group when the buffer is unmodified, or the `MatchParen` highlight
--- group if it is. This is to match LazyVim's `lualine` appearance.
---@param buf integer The number of our buffer
---@return table # A table of components to be displayed in the window statusline
local function incline_pretty_path(buf)
  local filename = vim.api.nvim_buf_get_name(buf)
  local display_path = vim.fn.fnamemodify(filename, ":~:.")
  local path = Path:new(display_path)
  local modified = vim.bo[buf].modified

  -- Skip for unnamed buffers
  if not path.filename or path.filename == "" then
    return { { "[no name]" } }
  end

  -- See if we can make it relative to the LazyVim project root.
  if package.loaded["lazyvim.util.root"] then
    local LazyRoot = require("lazyvim.util.root")
    local root = LazyRoot.get()

    if root then
      path = Path:new(path:make_relative(root))
    end
  end

  -- What follows is mostly borrowed from LazyVim's `pretty_path` function.
  -- https://github.com/LazyVim/LazyVim/blob/ec5981dfb1222c3bf246d9bcaa713d5cfa486fbd/lua/lazyvim/util/lualine.lua#L82

  local parts = vim.split(path.filename, "[\\/]")

  -- If the path is longer then `len` components, abbreviate the middle parts
  -- with an ellipsis.
  local len = 3
  if #parts > len then
    parts = { parts[1], "…", unpack(parts, #parts - len + 2, #parts) }
  end

  -- Use our namespace-specific highlight groups
  local modified_hl = "InclineModified"
  local filename_hl = "InclineFilename"
  local directory_hl = "InclineDirectory"

  -- Get the OS-specific path separator
  local sep = package.config:sub(1, 1)

  -- Add directory components if they exist
  local result = {}

  if #parts > 1 then
    for i = 1, #parts - 1 do
      if i > 1 then
        table.insert(result, { sep, group = directory_hl })
      end

      table.insert(result, { parts[i], group = directory_hl })
    end

    -- Add final separator before filename
    table.insert(result, { sep, group = directory_hl })
  end

  -- Add filename with appropriate highlight
  table.insert(result, { parts[#parts], group = modified and modified_hl or filename_hl })

  return result
end

return {
  {
    "b0o/incline.nvim",
    event = "BufReadPre",

    dependencies = {
      "plenary.nvim",
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
