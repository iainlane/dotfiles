-- Interactive text alignment from the `mini` ecosystem (already pulled in by
-- mini.ai, mini.surround and the rest). `ga` starts alignment and `gA` starts
-- it with a preview, matching the verbs the other mini plugins use.
return {
  "nvim-mini/mini.align",
  keys = {
    { "ga", mode = { "n", "x" }, desc = "Align" },
    { "gA", mode = { "n", "x" }, desc = "Align with preview" },
  },
  opts = {},
}
