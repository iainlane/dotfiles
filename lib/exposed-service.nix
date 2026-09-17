# The settings that decide how the reverse proxy serves a service: its domain
# name, and whether a visitor has to sign in first.
#
# A service declares an option of this type for the host to fill in, then passes
# the host's value to `exposePodman` along with its own port. The proxy and the
# services behind it both import this file. The settings are therefore described
# once, and every service offers the same ones to the host.
{lib, ...}: {
  options = {
    domain = lib.mkOption {
      type = lib.types.str;
      example = "thing.example.org";
      description = "The domain the service answers to.";
    };

    auth = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Require the proxy's single sign-on before a visitor can reach the
        service. This option defaults to true, so a host that serves something
        to anyone who asks has to set `auth = false` explicitly.
      '';
    };
  };
}
