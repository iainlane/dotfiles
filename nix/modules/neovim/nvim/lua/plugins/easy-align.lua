return {
  "junegunn/vim-easy-align",
  event = "VeryLazy",
  config = function()
    -- set keymaps
    local keymap = vim.keymap -- for conciceness

    keymap.set("x", "ga", "<Plug>(EasyAlign)", { desc = "EasyAlign interactive mode" })
    keymap.set("n", "ga", "<Plug>(EasyAlign)", { desc = "EasyAlign interactive mode" })
  end,
}
