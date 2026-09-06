-- https://github.com/lambdalisue/vim-suda
return {
  "lambdalisue/vim-suda",
  event = { "BufRead", "BufNewFile" },
  config = function()
    -- Smart edit mode switches to `suda://` when a file is not readable or
    -- writable.
    vim.g.suda_smart_edit = 1
  end,
  cmd = { "SudaRead", "SudaWrite" },
}
