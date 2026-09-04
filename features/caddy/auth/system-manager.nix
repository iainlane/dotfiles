# Single sign-on for the sites that ask for it, provided by one oauth2-proxy
# the whole host shares.
#
# Sites opt in individually: some must stay reachable unauthenticated, and a
# proxy that quietly authenticates them breaks them in ways that are hard to
# attribute. The proxy itself builds the sign-in routes and runs the container;
# this feature's presence is what tells it to.
{
  dotfiles.caddy.auth.present = true;
}
