--- Cache for storing config directories by file path
--- @type table<string, string>
local config_dir_cache = {}

--- Cache for storing Jest commands by file path
--- @type table<string, string>
local command_cache = {}

--- Finds a Jest configuration file in the given directory
---
--- @param dir string Directory to search in
--- @return string|nil Path to Jest config file or nil if not found
local function find_jest_config_in_dir(dir)
  local Path = require("plenary.path")

  -- First check for package.json
  local package_json_path = Path:new(dir .. "/package.json")
  if package_json_path:exists() then
    local content = vim.fn.json_decode(package_json_path:read())
    -- If package.json has jest configuration, use it
    if content and content.jest then
      return package_json_path:absolute()
    end
  end

  -- Then check for various jest config files in priority order
  local possible_configs = {
    "jest.config.ts",
    "jest.config.js",
    "jest.config.mjs",
    "jest.config.cjs",
    "jest.config.json",
  }

  for _, config_name in ipairs(possible_configs) do
    local config_path = Path:new(dir .. "/" .. config_name)
    if config_path:exists() then
      return config_path:absolute()
    end
  end

  -- No config found in this directory
  return nil
end

--- Finds a Jest configuration file by walking up the directory tree
---
--- @param path string File path to start searching from
--- @return string|nil Path to Jest config file or nil if not found
local function find_jest_config(path)
  local Path = require("plenary.path")
  local root = LazyVim.root()

  -- Start with the current buffer's directory
  local current_dir = Path:new(path):parent():absolute()

  -- Keep going up until we reach the project root
  while current_dir and current_dir ~= "" and vim.startswith(current_dir, root) do
    local config = find_jest_config_in_dir(current_dir)
    if config then
      -- Store the directory where we found the config
      config_dir_cache[path] = current_dir
      return config
    end

    -- Move up one directory
    current_dir = Path:new(current_dir):parent():absolute()
  end

  -- No config found, return default
  config_dir_cache[path] = nil
  return nil
end

--- Information about a package.json file
---
--- @class PackageJsonInfo
--- @field dir string Directory containing the package.json
--- @field has_test boolean Whether the package.json has a test script
--- @field package_json string Absolute path to the package.json file

--- Finds a package.json file with a test script by walking up the directory tree
---
--- @param path string File path to start searching from
--- @return PackageJsonInfo|nil Package info or nil if not found
local function find_package_json_with_test(path)
  local Path = require("plenary.path")
  local root = LazyVim.root()

  -- Start with the current buffer's directory
  local current_dir = Path:new(path):parent():absolute()

  local first_package_json = nil

  -- Keep going up until we reach the project root
  while current_dir and current_dir ~= "" and vim.startswith(current_dir, root) do
    local package_json_path = Path:new(current_dir .. "/package.json")
    if package_json_path:exists() then
      local content = vim.fn.json_decode(package_json_path:read())
      if content and content.scripts and content.scripts.test then
        return {
          dir = current_dir,
          has_test = true,
          package_json = package_json_path:absolute(),
        }
      end

      if not first_package_json then
        first_package_json = {
          dir = current_dir,
          has_test = false,
          package_json = package_json_path:absolute(),
        }
      end
    end

    -- Move up one directory
    current_dir = Path:new(current_dir):parent():absolute()
  end

  -- Return the first package.json found if no test script found. This is the
  -- one which is closest to our source file.
  return first_package_json
end

--- Finds the appropriate Jest command for the given file
---
--- @param path string File path to find Jest command for
--- @return string Jest command to run
local function find_jest_command(path)
  local Path = require("plenary.path")

  -- Check cache first
  if command_cache[path] then
    return command_cache[path]
  end

  -- Find package.json with test script
  local pkg_info = find_package_json_with_test(path)

  -- If no package.json found at all, use direct jest command
  if not pkg_info then
    command_cache[path] = "jest --"
    return command_cache[path]
  end

  local dir = pkg_info.dir

  -- Detect package manager in order of preference: pnpm > yarn > npm
  local package_managers = {
    { lock = "pnpm-lock.yaml", cmd = pkg_info.has_test and "pnpm test --" or "pnpm jest --" },
    { lock = "yarn.lock", cmd = pkg_info.has_test and "yarn test --" or "yarn jest --" },
    { lock = "package-lock.json", cmd = pkg_info.has_test and "npm test --" or "npm jest --" },
  }

  for _, pm in ipairs(package_managers) do
    local lock_file = Path:new(dir .. "/" .. pm.lock)
    if lock_file:exists() then
      command_cache[path] = pm.cmd
      return pm.cmd
    end
  end

  -- Default to npm if no lock file found
  local command = pkg_info.has_test and "npm test --" or "npm jest --"
  command_cache[path] = command
  return command
end

return {
  {
    "nvim-neotest/neotest-jest",
    event = "VeryLazy",
  },
  {
    "marilari88/neotest-vitest",
    event = "VeryLazy",
  },
  {
    "nvim-lua/plenary.nvim",
    lazy = true,
  },
  {
    "nvim-neotest/neotest",
    dependencies = {
      "nvim-lua/plenary.nvim",
    },
    opts = {
      adapters = {
        ["neotest-jest"] = {
          --- Gets the Jest config file path for the current test
          jestConfigFile = find_jest_config,

          --- Gets the appropriate Jest command for the current test
          jestCommand = find_jest_command,

          --- Determines the working directory for running tests
          cwd = function(path)
            -- First try to use the config directory
            if config_dir_cache[path] then
              return config_dir_cache[path]
            end

            -- Next try to use the directory with package.json that has a test script
            local pkg_info = find_package_json_with_test(path)
            if pkg_info then
              return pkg_info.dir
            end

            -- Otherwise use neotest-json's default
            return nil
          end,
        },
        ["neotest-vitest"] = {},
      },
    },
  },
}
