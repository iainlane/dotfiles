return {
  "mfussenegger/nvim-lint",

  optional = true,

  opts = {
    linters_by_ft = {
      nix = { "statix", "deadnix" },
      yaml = { "zizmor" },
    },

    linters = {
      zizmor = {
        ---zizmor audits GitHub Actions workflows and action definitions. Given
        ---any other YAML file it collects no inputs and exits with an error,
        ---so run it only for files directly under `.github/workflows` and for
        ---files named `action.yml` or `action.yaml`.
        ---@param ctx { filename: string, dirname: string }
        ---@return boolean
        condition = function(ctx)
          return vim.endswith(ctx.dirname, "/.github/workflows")
            or vim.fs.basename(ctx.filename):match("^action%.ya?ml$") ~= nil
        end,
      },
    },
  },
}
