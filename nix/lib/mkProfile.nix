{lib}:
# Conditionally add OS-specific imports to a profile.
#
# Usage: `imports = mkProfileImports ./. [ ../modules/bar ];`
#
# Optionally loads `./darwin.nix` or `./linux.nix` based on `hostConfig.os`,
# plus any extraImports passed in. The profile's `default.nix` is loaded by the
# module system before this function is called.
#
# Arguments:
#   hostConfig:    Host configuration with `os` field
#   profileDir:    Directory containing the profile (usually ./.)
#   extraImports:  List of additional modules to import
#
# Import order: extraImports are added first, then the OS-specific file. This
# allows the OS-specific file to override settings from extraImports when needed.
{
  mkProfileImports = hostConfig: profileDir: extraImports:
    assert lib.assertMsg (hostConfig ? os) "mkProfileImports: hostConfig must have an 'os' field";
    assert lib.assertMsg (builtins.isPath profileDir) "mkProfileImports: profileDir must be a path";
    assert lib.assertMsg (builtins.isList extraImports) "mkProfileImports: extraImports must be a list"; let
      osFile = profileDir + "/${hostConfig.os}.nix";
    in
      extraImports ++ lib.optional (builtins.pathExists osFile) osFile;
}
