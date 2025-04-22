local function get_my_review_requests()
  local octo_utils = require("octo.utils")

  local repo = octo_utils.get_remote_name()

  local octo_commands = require("octo.commands")

  octo_commands.search("is:open", "is:pr", "review-requested:@me", "repo:" .. repo, "sort:created-desc")
end

return {
  "pwntester/octo.nvim",

  opts = {
    picker = "snacks",
  },

  keys = {
    {
      "<leader>gr",
      get_my_review_requests,
      desc = "List My Review Requests (Octo)",
    },
    { "<leader>gR", "<cmd>Octo repo list<CR>", desc = "List Repos (Octo)" },
  },
}
