--- Cache for storing config directories by file path
--- @type table<string, string>
local config_dir_cache = {}

--- Cache for storing test commands by file path
--- @type table<string, string>
local command_cache = {}

--- @class Framework
--- @field package_json_key? string Key in package.json to look for
--- @field config_files string[] List of possible config file names
--- @field binary string Name of the test framework binary
--- @field default_command string Default command to run if no config found
--- @field package_name string The package name in dependencies

-- Framework-specific configurations

--- @type Framework
local jest_framework = {
  package_json_key = "jest",
  config_files = {
    "jest.config.ts",
    "jest.config.js",
    "jest.config.mjs",
    "jest.config.cjs",
    "jest.config.json",
  },
  binary = "jest",
  default_command = "jest --",
  package_name = "jest",
}

--- @type Framework
local vitest_framework = {
  config_files = {
    "vitest.config.ts",
    "vitest.config.js",
    "vitest.config.mjs",
    "vitest.config.cjs",
    "vite.config.ts",
    "vite.config.js",
  },
  binary = "vitest",
  default_command = "vitest",
  package_name = "vitest",
}

--- Find a test configuration file in a directory
---
--- @param dir string Directory to look in
--- @param framework Framework Framework-specific settings
--- @return string|nil Path to config file or nil if not found
local function find_test_config_in_dir(dir, framework)
  local Path = require("plenary.path")

  -- First check package.json
  local package_json_path = Path:new(dir .. "/package.json")
  if framework.package_json_key and package_json_path:exists() then
    local content = vim.fn.json_decode(package_json_path:read())
    -- If package.json has framework configuration, use it
    if content and content[framework.package_json_key] then
      return package_json_path:absolute()
    end
  end

  -- Then check for various config files in priority order
  local possible_configs = framework.config_files
  for _, config_name in ipairs(possible_configs) do
    local config_path = Path:new(dir .. "/" .. config_name)
    if config_path:exists() then
      return config_path:absolute()
    end
  end

  -- No config found in this directory
  return nil
end

--- Finds a test configuration file by walking up the directory tree
---
--- @param path string File path to start searching from
--- @param framework Framework Framework-specific settings
--- @return string|nil Path to config file or nil if not found
local function find_test_config(path, framework)
  local Path = require("plenary.path")
  local root = LazyVim.root()

  if config_dir_cache[path] then
    return config_dir_cache[path]
  end

  -- Start with the current buffer's directory
  local current_dir = Path:new(path):parent():absolute()

  -- Keep going up until we reach the project root
  while current_dir and current_dir ~= "" and vim.startswith(current_dir, root) do
    local config = find_test_config_in_dir(current_dir, framework)
    if config then
      -- Store the directory where we found the config
      config_dir_cache[path] = config
      return config
    end

    -- Move up one directory
    current_dir = Path:new(current_dir):parent():absolute()
  end

  -- No config found, return default
  config_dir_cache[path] = nil
  return nil
end

--- Check if a directory has the framework's binary in node_modules
---
--- @param dir string Directory to check
--- @param framework Framework Framework-specific settings
--- @return boolean Whether the binary exists in node_modules
local function has_framework_binary(dir, framework)
  local Path = require("plenary.path")
  local bin_path = Path:new(dir .. "/node_modules/.bin/" .. framework.binary)
  return bin_path:exists()
end

--- Check if a package.json has the framework as a dependency
---
--- @param package_json_path string Path to package.json
--- @param framework Framework Framework-specific settings
--- @return boolean Whether the framework is listed as a dependency
local function has_framework_dependency(package_json_path, framework)
  local Path = require("plenary.path")
  local path = Path:new(package_json_path)

  if not path:exists() then
    return false
  end

  local content = vim.fn.json_decode(path:read())
  if not content then
    return false
  end

  -- Check both dependencies and devDependencies
  if content.dependencies and content.dependencies[framework.package_name] then
    return true
  end

  if content.devDependencies and content.devDependencies[framework.package_name] then
    return true
  end

  return false
end

--- Find the most appropriate directory to run tests from (where the framework is installed)
---
--- @param path string File path to start searching from
--- @param framework Framework Framework-specific settings
--- @return string Directory where the framework is installed, or the root directory
local function find_best_test_dir(path, framework)
  local Path = require("plenary.path")
  local root = LazyVim.root()

  -- Start with the current buffer's directory
  local current_dir = Path:new(path):parent():absolute()

  -- Keep going up until we reach the project root
  while current_dir and current_dir ~= "" and vim.startswith(current_dir, root) do
    -- Check if binary exists in node_modules - this is the most reliable indicator
    if has_framework_binary(current_dir, framework) then
      return current_dir
    end

    -- Check if framework is in dependencies
    local package_json_path = current_dir .. "/package.json"
    if has_framework_dependency(package_json_path, framework) then
      return current_dir
    end

    -- Move up one directory
    current_dir = Path:new(current_dir):parent():absolute()
  end

  -- If no directory with the framework found, use root
  return root
end

--- Detect package manager for a directory
---
--- @param dir string Directory to check
--- @return string Package manager command prefix
local function detect_package_manager(dir)
  local Path = require("plenary.path")

  if Path:new(dir .. "/pnpm-lock.yaml"):exists() then
    return "pnpm"
  elseif Path:new(dir .. "/yarn.lock"):exists() then
    return "yarn"
  elseif Path:new(dir .. "/package-lock.json"):exists() then
    return "npm"
  end

  -- Check parent directories (only up to the project root)
  local current_dir = Path:new(dir):parent():absolute()
  local root = LazyVim.root()

  while current_dir and current_dir ~= "" and vim.startswith(current_dir, root) do
    if Path:new(current_dir .. "/pnpm-lock.yaml"):exists() then
      return "pnpm"
    elseif Path:new(current_dir .. "/yarn.lock"):exists() then
      return "yarn"
    elseif Path:new(current_dir .. "/package-lock.json"):exists() then
      return "npm"
    end

    current_dir = Path:new(current_dir):parent():absolute()
  end

  -- Default to npx if no lock files found
  return "npx"
end

--- Check if package.json has a test script that uses the framework
---
--- @param dir string Directory with package.json
--- @param framework Framework Framework settings
--- @return boolean Whether package.json has a suitable test script
local function has_framework_test_script(dir, framework)
  local Path = require("plenary.path")
  local package_json_path = Path:new(dir .. "/package.json")

  if not package_json_path:exists() then
    return false
  end

  local content = vim.fn.json_decode(package_json_path:read())
  return content and content.scripts and content.scripts.test and vim.startswith(content.scripts.test, framework.binary)
end

--- Builds the appropriate test command based on package manager and framework
---
--- @param dir string Directory to use
--- @param framework Framework Framework settings
--- @return string Complete test command
local function build_test_command(dir, framework)
  local pm = detect_package_manager(dir)
  local has_test = has_framework_test_script(dir, framework)

  local cmd = pm .. " test --"
  if not has_test then
    cmd = pm .. " " .. framework.binary
  end

  return cmd
end

--- Finds the appropriate test command for the given file
---
--- @param path string File path to find test command for
--- @param framework Framework Framework-specific settings
--- @return string Test command to run
local function find_test_command(path, framework)
  -- Check cache first
  if command_cache[path] then
    return command_cache[path]
  end

  -- Find best directory to run tests from
  local test_dir = find_best_test_dir(path, framework)

  -- Build command based on package manager and directory
  local command = build_test_command(test_dir, framework)

  command_cache[path] = command
  return command
end

--- Finds the working directory to use to run tests for the given path
---
--- @param path string File path to find working directory for
--- @param framework Framework Framework-specific settings
--- @return string Working directory to use
local function get_cwd(path, framework)
  -- Use the directory where the framework is actually installed
  return find_best_test_dir(path, framework)
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
          jestConfigFile = function(path)
            return find_test_config(path, jest_framework)
          end,
          jestCommand = function(path)
            return find_test_command(path, jest_framework)
          end,
          cwd = function(path)
            return get_cwd(path, jest_framework)
          end,
        },
        ["neotest-vitest"] = {
          vitestConfigFile = function(path)
            local config = find_test_config(path, vitest_framework)
            print(config)
            return config
          end,
          vitestCommand = function(path)
            local cmd = find_test_command(path, vitest_framework)
            print(cmd)
            return cmd .. " --coverage --coverage.reporter=lcov"
          end,
          cwd = function(path)
            local cwd = get_cwd(path, vitest_framework)
            print(cwd)
            return cwd
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
