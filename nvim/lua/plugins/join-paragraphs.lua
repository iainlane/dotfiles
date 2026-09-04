return {
  dir = vim.fn.stdpath("config") .. "/lua/join-paragraphs/",

  cmd = { "JoinParagraphs", "Rj" },

  keys = {
    { "<Leader>jj", mode = { "n", "x" }, desc = "Join Paragraphs" },
    { "<Leader>jp", mode = { "n", "x" }, desc = "Paste and Join Paragraphs" },
  },

  config = function()
    require("join-paragraphs").setup()
  end,
}
