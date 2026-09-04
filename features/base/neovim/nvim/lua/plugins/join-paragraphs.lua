return {
  dir = vim.fn.stdpath("config") .. "/lua/join-paragraphs/",

  cmd = { "JoinParagraphs", "Rj" },

  keys = {
    { "<Leader>jj", desc = "Join Paragraphs" },
    { "<Leader>jp", desc = "Paste and Join Paragraphs" },
  },

  config = function()
    require("join-paragraphs").setup()
  end,
}
