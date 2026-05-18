local function p(fn)
  return function()
    require("presenterm")[fn]()
  end
end

local function picker(mod, fn)
  return function()
    require("presenterm." .. mod)[fn]()
  end
end

return {
  "Piotr1215/presenterm.nvim",
  ft = { "markdown" },
  opts = {
    default_keybindings = false,
  },
  keys = {
    { "]>", p("next_slide"), desc = "Next slide", ft = "markdown" },
    { "[<", p("previous_slide"), desc = "Previous slide", ft = "markdown" },
    { "<leader>>n", p("new_slide"), desc = "New slide", ft = "markdown" },
    { "<leader>>s", p("split_slide"), desc = "Split slide", ft = "markdown" },
    { "<leader>>d", p("delete_slide"), desc = "Delete slide", ft = "markdown" },
    { "<leader>>y", p("yank_slide"), desc = "Yank slide", ft = "markdown" },
    { "<leader>>v", p("select_slide"), desc = "Select slide", ft = "markdown" },
    { "<leader>>k", p("move_slide_up"), desc = "Move slide up", ft = "markdown" },
    { "<leader>>j", p("move_slide_down"), desc = "Move slide down", ft = "markdown" },
    { "<leader>>R", p("interactive_reorder"), desc = "Interactive reorder", ft = "markdown" },
    { "<leader>>l", picker("pickers", "slide_picker"), desc = "Slide picker", ft = "markdown" },
    { "<leader>>L", picker("layout", "layout_picker"), desc = "Layout picker", ft = "markdown" },
    { "<leader>>p", picker("pickers", "partial_picker"), desc = "Partial picker", ft = "markdown" },
    { "<C-e>", p("toggle_exec"), desc = "Toggle exec", mode = { "n", "i" }, ft = "markdown" },
    { "<leader>>r", p("run_code_block"), desc = "Run code block", ft = "markdown" },
    { "<leader>>P", p("preview"), desc = "Preview presentation", ft = "markdown" },
    { "<leader>>c", p("presentation_stats"), desc = "Presentation stats", ft = "markdown" },
  },
}
