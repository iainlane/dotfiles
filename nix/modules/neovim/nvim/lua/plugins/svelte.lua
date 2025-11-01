-- We install `svelte-language-server` via Nix. This patches the LazyVim Svelte
-- extra to find that version.
return {
  {
    "neovim/nvim-lspconfig",
    opts = function(_, opts)
      local global_plugins = vim.tbl_get(opts, "servers", "vtsls", "settings", "vtsls", "tsserver", "globalPlugins")
      if type(global_plugins) ~= "table" then
        return
      end

      local svelteserver = vim.fn.exepath("svelteserver")
      if svelteserver == "" then
        return
      end

      local nix_plugin_location = vim.fs.normalize(
        vim.fs.dirname(svelteserver) .. "/../lib/node_modules/svelte-language-server/packages/typescript-plugin"
      )

      for _, plugin in ipairs(global_plugins) do
        if plugin.name == "typescript-svelte-plugin" then
          plugin.location = nix_plugin_location
          return
        end
      end
    end,
  },
}
