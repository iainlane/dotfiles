return {
  "neovim/nvim-lspconfig",

  -- Extend `yamlls` from `lazyvim.plugins.extras.lang.yaml` with CloudFormation
  -- tags
  opts = function(_, opts)
    local cfn_tags = {
      "!And scalar",
      "!Base64 scalar",
      "!Cidr sequence",
      "!Equals sequence",
      "!FindInMap sequence",
      "!GetAtt scalar",
      "!GetAtt sequence",
      "!GetAZs",
      "!If sequence",
      "!ImportValue scalar",
      "!Join sequence",
      "!Not sequence",
      "!Or sequence",
      "!Ref scalar",
      "!Select sequence",
      "!Split sequence",
      "!Sub scalar",
    }

    local existing_tags = vim.tbl_get(opts, "servers", "yamlls", "settings", "yaml", "customTags") or {}

    opts.servers = vim.tbl_deep_extend("force", opts.servers or {}, {
      yamlls = {
        settings = {
          yaml = {
            customTags = vim.list_extend(existing_tags, cfn_tags),
          },
        },
      },
    })

    return opts
  end,
}
