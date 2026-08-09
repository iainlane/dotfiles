# The values that both AgentsView profiles use.
#
# Each machine keeps an archive of its agent sessions. Some machines push
# their archive to a shared database. One machine holds that database and
# shows a dashboard of it.
#
# The two profiles must agree on three things: which machines push, where
# they push to, and which certificate each machine presents.
#
# This file reads the answers from the host records. To add a machine, add
# the profile to it. Host discovery reads the files under `hosts/` directly,
# so a profile can call these functions safely.
{lib}: let
  helpers = import ./profiles.nix {inherit lib;};

  clientProfile = "agentsview";
  serverProfile = "agentsview-server";

  # A work machine keeps its archive on the machine. It does not push.
  pushes = host: helpers.hasProfile host clientProfile && !helpers.hasProfile host "work";

  # Settings a host passes to one of its profiles.
  profileSettings = name: host: let
    matching =
      lib.filter
      (entry: entry.name == name)
      (helpers.normaliseProfileEntries host.profiles);
  in
    if matching == []
    then {}
    else (lib.head matching).profileOptions or {};

  syncingHosts = hosts: lib.filterAttrs (_: pushes) hosts;

  serverDefaults = {
    database = "agentsview";
  };

  # Each machine connects as itself and has its own password. You can remove
  # the access of one machine and the others keep theirs.
  role = hostname: hostname;

  # The machine that shows the dashboard, and the settings it was given. The
  # clients read the hostname from here, so the file gives it one time.
  serverSettings = hosts: let
    found = lib.filterAttrs (_: host: helpers.hasProfile host serverProfile) hosts;
  in
    if found == {}
    then null
    else serverDefaults // profileSettings serverProfile (lib.head (lib.attrValues found));

  # The certificate of a machine is beside its host record. The path comes
  # from the hostname, so the server finds each certificate itself. No list of
  # them is necessary.
  certificatePath = hostname: ../hosts + "/${hostname}/agentsview.pem";

  hasCertificate = hostname: builtins.pathExists (certificatePath hostname);

  # A machine that pushes needs two secrets. Both paths come from the
  # hostname, so a machine does not state where its own secrets are.
  #
  # The first secret is the password of the database role. The server reads
  # the password of every machine and keeps the roles correct.
  #
  # The second secret is the private key of the certificate. It belongs to the
  # user that runs the push, so it sits with the other user secrets.
  #
  # A password goes into a connection URL. Make it with
  # `openssl rand -hex 32`. A password that contains `/`, `#`, `?` or `:`
  # reads as a port or a path, and the connection fails.
  passwordFile = hostname: "agentsview-postgres/${hostname}.yaml";
  passwordSecret = "password";

  # The secrets that belong to the user on one machine. The server reads the
  # password file above to make the roles, and it has no part in these.
  userSecretsFile = hostname: "${hostname}/user-agentsview.yaml";
  privateKeySecret = "agentsview_client_key";

  # AgentsView makes these two values at the first start and writes them into
  # its own configuration. The configuration here is read-only, thus they come
  # with it. Make each one with `openssl rand -base64 32`.
  #
  # The first value signs the cursors of the dashboard. The second one
  # authenticates a caller to the API of the dashboard.
  cursorSecret = "agentsview_cursor_secret";
  authTokenSecret = "agentsview_auth_token";

  # The name of a secret contains the machine that owns it. One host can hold
  # the secrets of several machines and keep them apart.
  passwordSecretFor = hostname: "agentsview_password_${hostname}";
in {
  inherit
    authTokenSecret
    certificatePath
    clientProfile
    cursorSecret
    hasCertificate
    passwordFile
    passwordSecret
    passwordSecretFor
    privateKeySecret
    userSecretsFile
    profileSettings
    pushes
    role
    serverDefaults
    serverProfile
    serverSettings
    syncingHosts
    ;
}
