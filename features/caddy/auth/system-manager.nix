# Single sign-on for the sites that ask for it, provided by one oauth2-proxy
# the whole host shares.
#
# Sites opt in individually: some have to stay reachable without signing in,
# and putting a sign-in gate in front of one of those breaks it in ways that
# are hard to attribute. The caddy feature builds the sign-in routes and runs
# the container; this feature only sets `present`.
{
  dotfiles.caddy.auth.present = true;
}
