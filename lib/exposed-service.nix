# The settings that decide how a service is served by the reverse proxy: the
# name it answers to, and whether a visitor has to sign in before reaching it.
#
# A service declares an option of this type for the host to fill in, then passes
# what the host set to `exposePodman` along with the port it listens on. The
# proxy and the services it fronts both import this file, so the settings are
# described once and every service offers the host the same ones.
{lib, ...}: {
  options = {
    domain = lib.mkOption {
      type = lib.types.str;
      example = "thing.example.org";
      description = "Public host name the service answers to.";
    };

    auth = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Require the proxy's single sign-on before the service is reached.
        Serving something to anyone who asks is the decision worth stating, so
        it is the one that has to be written down.
      '';
    };
  };
}
