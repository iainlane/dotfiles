return {
  {
    "nvimtools/none-ls.nvim",
    init = function()
      LazyVim.on_very_lazy(function()
        -- Find the none-ls formatter and change its priority
        for _, formatter in ipairs(LazyVim.format.formatters) do
          if formatter.name == "none-ls.nvim" then
            formatter.priority = 50
            formatter.primary = false
            break
          end
        end
      end)
    end,
  },
}
