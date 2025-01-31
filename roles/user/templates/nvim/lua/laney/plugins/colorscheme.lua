return {
  "lifepillar/vim-solarized8",
  -- Using catppuccin for now
  enabled = false,
  priority = 1000,
  config = function()
    vim.cmd("colorscheme solarized8")
  end,
}
