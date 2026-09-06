{lib, ...}: {
  options.dotfiles.caddy.originAuth = {
    caFile = lib.mkOption {
      type = lib.types.path;
      default = ./cloudflare-origin-pull-ca.pem;
      description = ''
        Authority the client certificate must be signed by. Defaults to a
        copy of Cloudflare's origin pull authority, published at
        <https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem>
        and replaced when Cloudflare rotates it.
      '';
    };

    directSources = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["192.168.1.0/24" "2001:db8::/48"];
      description = ''
        Addresses served without being asked for a certificate. Clients on
        these networks reach the host directly, so they have no Cloudflare
        certificate to present. Podman container ranges from
        `dotfiles.containers.subnetPools` are also exempt, so services can
        contact the identity provider through the proxy. Other clients must
        present a valid certificate signed by `caFile`.
      '';
    };
  };
}
