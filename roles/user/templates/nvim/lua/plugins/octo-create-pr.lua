return {
  "iainlane/octo-create-pr.nvim",

  dev = true,

  dependencies = {
    "pwntester/octo.nvim",
  },

  cmd = "OctoCreatePR",

  keys = {
    "<leader>gX",
    "<cmd>OctoCreatePR<CR>",
    desc = "Create PR (Octo)",
  },
}
