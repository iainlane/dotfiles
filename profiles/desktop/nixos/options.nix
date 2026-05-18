{lib, ...}: {
  options.dotfiles.desktop.usbguard.staticRules = lib.mkOption {
    type = lib.types.attrsOf lib.types.lines;
    default = {};
    description = ''
      Declarative usbguard rule snippets rendered into /etc/usbguard/rules.d/.
      The attribute name is the file name and the value is the file content.
    '';
  };
}
