-- The `claudecode` extra conflicts with `avante`: both map various `<leader>a`
-- keybindings. Here we prefix the keybindings with `<leader>ao` to avoid that.
return {
  "coder/claudecode.nvim",
  opts = {},
  keys = {
    { "<leader>a", "", desc = "+ai", mode = { "n", "v" } },
    { "<leader>ao", "", desc = "+claude code", mode = { "n", "v" } },
    { "<leader>aoc", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>aof", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
    { "<leader>aor", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
    { "<leader>aoC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
    { "<leader>aob", "<cmd>ClaudeCodeAdd %<cr>", desc = "Add current buffer" },
    { "<leader>aos", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
    {
      "<leader>aos",
      "<cmd>ClaudeCodeTreeAdd<cr>",
      desc = "Add file",
      ft = { "NvimTree", "neo-tree", "oil" },
    },
    -- Diff management
    { "<leader>aoa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>aod", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
  },
}
