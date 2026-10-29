return {
  "yetone/avante.nvim",
  pin = true,
  build = "bash ./build.sh",
  dependencies = {
    { "ColinKennedy/mega.cmdparse", dependencies = { "ColinKennedy/mega.logging" } },
  },
}
