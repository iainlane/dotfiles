-- The upstream jest/vitest adapters walk up the tree from the buffer's path
-- to find the nearest config file and the local `node_modules/.bin/<binary>`.
--
-- The logic here wraps the adapter command in the project's package manager
-- (e.g. `pnpm test --`), so that `"test"`-script arguments configured in
-- package.json (TS loaders, setup files, ...) apply under neotest too.

---Walk up from `dir` to the project root, returning the first directory that
---contains one of `names` along with the name that matched there.
---@param dir string
---@param names string[]
---@return string|nil directory
---@return string|nil name
local function find_up(dir, names)
  local root = LazyVim.root()
  local current = dir

  while current and current ~= "" and vim.startswith(current, root) do
    for _, name in ipairs(names) do
      if vim.uv.fs_stat(current .. "/" .. name) then
        return current, name
      end
    end

    local parent = vim.fs.dirname(current)
    if parent == current then
      break
    end

    current = parent
  end

  return nil, nil
end

---How each package manager, recognised by its lockfile, runs the project's
---`test` script and a binary from `node_modules`. npm needs `exec` for the
---binary and a `--` before the binary's own arguments; `npm <binary>` is not
---a command npm has.
local package_managers = {
  ["pnpm-lock.yaml"] = { test_script = "pnpm test --", binary = "pnpm exec %s" },
  ["yarn.lock"] = { test_script = "yarn test --", binary = "yarn exec %s" },
  ["package-lock.json"] = { test_script = "npm test --", binary = "npm exec %s --" },
}

---Returns true when the nearest `package.json`, searched from `dir` up to the
---project root, has a `test` script starting with `binary`, so running that
---script keeps the arguments it sets.
---@param dir string
---@param binary string
---@return boolean
local function has_framework_test_script(dir, binary)
  local package_dir = find_up(dir, { "package.json" })
  if not package_dir then
    return false
  end

  local ok, content = pcall(vim.fn.readfile, package_dir .. "/package.json")
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

---Build the test command for a neotest position using the project's package
---manager.
---@param path string Absolute path of the position: a test file, or a directory.
---@param binary string Framework binary (e.g. `jest`, `vitest`).
---@return string
local function build_test_command(path, binary)
  local stat = vim.uv.fs_stat(path)
  local dir = stat and stat.type == "directory" and path or vim.fs.dirname(path)

  local _, lockfile = find_up(dir, { "pnpm-lock.yaml", "yarn.lock", "package-lock.json" })
  if not lockfile then
    return "npx " .. binary
  end

  local commands = package_managers[lockfile]
  if has_framework_test_script(dir, binary) then
    return commands.test_script
  end

  return commands.binary:format(binary)
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
