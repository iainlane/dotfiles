{lib, ...}: {
  options.dotfiles.ai = lib.genAttrs ["anthropicApiKeyFile" "openaiApiKeyFile" "openrouterApiKeyFile"] (_:
    lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host-owned provider credential file. Consumers read the file only when their feature is enabled.";
    });
}
