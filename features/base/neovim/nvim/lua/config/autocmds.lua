-- Monorepo ergonomics: when a real file becomes visible in a window, point the
-- window's local cwd at the nearest language-module root, so `:!`, `:term`,
-- `:grep` and other tools that consult cwd run from the project being edited.
--
-- LSP `root_dir` is decided independently from the buffer's path at attach
-- time, so this does not change which server attaches; it only aligns shell and
-- quickfix tooling with the module.
local markers = {
  "go.work",
  "go.mod",
  "Cargo.toml",
  "pyproject.toml",
  "package.json",
}

vim.api.nvim_create_autocmd("BufWinEnter", {
  group = vim.api.nvim_create_augroup("monorepo_lcd", { clear = true }),
  callback = function(args)
    if vim.bo[args.buf].buftype ~= "" then
      return
    end

    local name = vim.api.nvim_buf_get_name(args.buf)
    if name == "" or name:match("^%w+://") then
      return
    end

    local root = vim.fs.root(args.buf, { markers })
    if not root then
      return
    end

    vim.fn.chdir(root, "window")
  end,
})
