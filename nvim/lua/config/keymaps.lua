vim.keymap.set("n", "<leader>nh", ":nohl<CR>", { desc = "Clear search highlights" })
vim.keymap.set("n", "<leader>+", "<C-a>", { desc = "Increment number" })

-- LazyVim loads its own keymaps file immediately before this one, so a mapping
-- set here replaces LazyVim's. `<leader>wm` was snacks's zoom, which LazyVim
-- also maps at `<leader>uZ`. A `keys` entry in the plugin spec would not work:
-- lazy.nvim installs those before LazyVim's keymaps run.
vim.keymap.set("n", "<leader>wm", "<cmd>MaximizerToggle<CR>", { desc = "Maximize/minimize a split" })

Snacks.toggle.zen():map("<leader>z")
Snacks.toggle.zoom():map("<leader>Z")
