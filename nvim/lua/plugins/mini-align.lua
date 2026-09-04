-- Interactive text alignment via the `mini` ecosystem (already pulled in by
-- mini.ai, mini.surround, etc.). `ga` starts alignment, `gA` starts it with
-- preview - matches the verbs used by other mini plugins.
return {
  "nvim-mini/mini.align",
  keys = {
    { "ga", mode = { "n", "x" }, desc = "Align" },
    { "gA", mode = { "n", "x" }, desc = "Align with preview" },
  },
  opts = {},
}
