{lib}: {
  hasKey = path: key:
    builtins.pathExists path
    && lib.any (lib.hasPrefix "${key}:") (lib.splitString "\n" (builtins.readFile path));
}
