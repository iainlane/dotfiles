-- The upstream jest/vitest adapters walk up the tree from the buffer's path
-- to find the nearest config file and the local `node_modules/.bin/<binary>`.
--
-- The logic here wraps the adapter command in the project's package manager
-- (e.g. `pnpm test --`), so that `"test"`-script arguments configured in
-- package.json (TS loaders, setup files, ...) apply under neotest too.

---Find the nearest package manager by walking up from `dir` to the project root.
---@param dir string
---@return string
local function detect_package_manager(dir)
  local root = LazyVim.root()
  local current = dir
  while current and current ~= "" and vim.startswith(current, root) do
    if vim.uv.fs_stat(current .. "/pnpm-lock.yaml") then
      return "pnpm"
    end
    if vim.uv.fs_stat(current .. "/yarn.lock") then
      return "yarn"
    end
    if vim.uv.fs_stat(current .. "/package-lock.json") then
      return "npm"
    end
    local parent = vim.fs.dirname(current)
    if parent == current then
      break
    end
    current = parent
  end
  return "npx"
end

---Returns true when `<dir>/package.json` has a `test` script starting with `binary`.
---@param dir string
---@param binary string
---@return boolean
local function has_framework_test_script(dir, binary)
  local path = dir .. "/package.json"
  if not vim.uv.fs_stat(path) then
    return false
  end
  local ok, content = pcall(vim.fn.readfile, path)
  if not ok then
    return false
  end
  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(content, "\n"))
  if not decoded_ok or type(decoded) ~= "table" then
    return false
  end
  local test_script = decoded.scripts and decoded.scripts.test
  return type(test_script) == "string" and vim.startswith(test_script, binary)
end

---Build the test command for a buffer using the project's package manager.
---@param path string Absolute file path the test is being run from.
---@param binary string Framework binary (e.g. `jest`, `vitest`).
---@return string
local function build_test_command(path, binary)
  local dir = vim.fs.dirname(path)
  local pm = detect_package_manager(dir)
  if has_framework_test_script(dir, binary) then
    return pm .. " test --"
  end
  return pm .. " " .. binary
end

return {
  { "nvim-neotest/neotest-jest", event = "VeryLazy" },
  { "marilari88/neotest-vitest", event = "VeryLazy" },
  { "nvim-lua/plenary.nvim", lazy = true },

  {
    "nvim-neotest/neotest",
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = {
      adapters = {
        ["neotest-jest"] = {
          jestCommand = function(path)
            return build_test_command(path, "jest")
          end,
        },
        ["neotest-vitest"] = {
          vitestCommand = function(path)
            -- Append coverage flags so `nvim-coverage` finds the lcov output.
            return build_test_command(path, "vitest") .. " --coverage --coverage.reporter=lcov"
          end,
          filter_dir = function(name)
            return name ~= "node_modules"
          end,
        },
      },
    },
  },

  {
    "andythigpen/nvim-coverage",

    opts = {
      auto_reload = true,
      commands = true,
      lcov_file = "coverage/lcov.info",
    },

    keys = {
      {
        "<leader>tc",
        function()
          local coverage = require("coverage")

          coverage.load(false)
          coverage.toggle()
        end,
        desc = "Toggle coverage",
      },
      {
        "<leader>tC",
        function()
          local coverage = require("coverage")

          coverage.load(false)
          coverage.summary()
        end,
        desc = "Show coverage summary",
      },
    },
  },
}
