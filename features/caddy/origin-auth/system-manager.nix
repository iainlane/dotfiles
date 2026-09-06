# Refusing connections that did not arrive through the content delivery network
# in front of this host.
#
# Cloudflare presents a client certificate when it connects to the origin, so
# someone who has found the host's own address cannot reach the services behind
# it directly. The caddy feature writes the TLS connection policies and mounts
# the certificate authority; this feature only sets `present`.
{
  dotfiles.caddy.originAuth.present = true;
}
