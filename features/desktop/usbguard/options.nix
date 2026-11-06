{lib, ...}: let
  inherit (lib) mkOption types;

  ruleType = types.submodule {
    options = {
      target = mkOption {
        type = types.enum ["allow" "block" "reject"];
        description = "Whether to authorise, block or remove matching devices.";
      };

      id = mkOption {
        type = types.strMatching "([[:xdigit:]]{4}|\\*):([[:xdigit:]]{4}|\\*)";
        example = "1235:8219";
        description = "USB vendor and product IDs, each four hexadecimal digits or `*`.";
      };

      serial = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "USB serial number to match. Null omits the serial constraint.";
      };

      hash = mkOption {
        type = types.nullOr (types.strMatching "[A-Za-z0-9+/]{43}=");
        default = null;
        description = "Base64-encoded SHA-256 device hash reported by USBGuard.";
      };

      label = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Descriptive rule label. Labels do not constrain device matching.";
      };
    };
  };
in {
  options.dotfiles.usbguard.staticRules = lib.mkOption {
    type = types.attrsOf (types.listOf ruleType);
    default = {};
    description = ''
      Declarative USBGuard rules grouped by file in /etc/usbguard/rules.d/.
      Files are read in lexical order, and each list preserves rule order.
      Rules support single values for ID, serial, hash and label attributes.
    '';
  };
}
