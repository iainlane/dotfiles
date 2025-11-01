-- https://github.com/lambdalisue/vim-suda
return {
  "lambdalisue/vim-suda",
  event = { "BufRead", "BufNewFile" },
  config = function()
    -- Enable smart edit mode - automatically switches to suda:// when files are not readable/writable
    vim.g.suda_smart_edit = 1
  end,
  cmd = { "SudaRead", "SudaWrite" },
}
