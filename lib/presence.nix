# How a child feature tells the rest of its parent that it is composed.
#
# A child defines one boolean option that its parent declares, and the parent
# branches on that value. The parent declares it so that the option exists on
# a host that excludes the child, where the parent reads `false`.
#
# The option is not a switch: the child's own module is what defines it.
# `assertions` counts the files that define the option and refuses more than
# one, so a host that sets it is told to change its composition.
{lib}: {
  option = subject:
    lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this host includes ${subject}. The feature's own module
        defines this. Give the host the feature, or list it in the host's
        `excludes`, to change the value.
      '';
    };

  assertions = options:
    map (
      path: let
        inherit (lib.getAttrFromPath path options) files;
      in {
        assertion = lib.length files <= 1;
        message = ''
          ${lib.showOption path} says whether a feature is part of this
          host, so only that feature's own module may define it. It is
          defined in ${lib.concatStringsSep " and " files}. Leave the option
          unset: compose the feature, or list it in the host's `excludes`.
        '';
      }
    );
}
