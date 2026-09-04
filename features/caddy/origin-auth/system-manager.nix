# Refusing connections that did not arrive through the content delivery network
# in front of this host.
#
# The network holds a client certificate and presents it when connecting, so
# someone who has found the host's own address cannot reach the services behind
# it directly. The proxy writes the TLS connection policies and mounts the
# authority; this feature's presence is what tells it to.
{
  dotfiles.caddy.originAuth.present = true;
}
