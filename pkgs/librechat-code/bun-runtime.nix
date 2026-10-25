{
  bun,
  fetchurl,
  stdenv,
}: let
  sources = {
    aarch64-darwin = {
      archive = "bun-darwin-aarch64.zip";
      hash = "sha256-wkDX8My5DCY6hJ/NsJt+5iYw2SE0jtaq/ahrnVd7xRA=";
    };
    aarch64-linux = {
      archive = "bun-linux-aarch64.zip";
      hash = "sha256-uqa7NvUdblhWHgK76oJQOKnfRU9nPW13bou/hvjHhQ4=";
    };
    x86_64-linux = {
      archive = "bun-linux-x64-baseline.zip";
      hash = "sha256-4ERutVmVdy65iUvrrppr42jZhai5Jx7hJEhvmUbu3XY=";
    };
  };

  source = sources.${stdenv.hostPlatform.system};
in
  bun.overrideAttrs {
    version = "1.4.4";
    src = fetchurl {
      url = "https://github.com/oven-sh/bun/releases/download/bun-v1.4.4/${source.archive}";
      inherit (source) hash;
    };
  }
