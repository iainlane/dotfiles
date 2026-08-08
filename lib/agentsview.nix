# What the two AgentsView profiles need to agree on.
#
# Machines keep their own archive of agent sessions and push it to a shared
# database, which one machine serves a dashboard from. Both ends need to agree
# on which machines push, where they push to, and which certificate each one
# presents.
#
# All of that is worked out from the host records, so adding the profile to a
# machine is all it takes. Host discovery reads the files under `hosts/`
# directly and never resolves a profile, so reading it from a profile does not
# feed back on itself.
{lib}: let
  helpers = import ./profiles.nix {inherit lib;};

  clientProfile = "agentsview";
  serverProfile = "agentsview-server";

  # Work stays on the machine it happened on, so a work machine keeps its
  # archive and pushes nothing.
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

  # Each machine connects as itself, with a password of its own, so taking one
  # machine's access away leaves the others alone.
  role = hostname: hostname;

  # The one machine serving the dashboard, and the settings it was given. The
  # clients read the hostname to push to from here, so it is written down once.
  serverSettings = hosts: let
    found = lib.filterAttrs (_: host: helpers.hasProfile host serverProfile) hosts;
  in
    if found == {}
    then null
    else serverDefaults // profileSettings serverProfile (lib.head (lib.attrValues found));

  # A machine's certificate lives beside its host record. Nothing lists them:
  # the path follows from the hostname, so the server finds each one for
  # itself.
  certificatePath = hostname: ../hosts + "/${hostname}/agentsview.pem";

  hasCertificate = hostname: builtins.pathExists (certificatePath hostname);

  # The two secrets a pushing machine needs. Both paths follow from the
  # hostname, so no machine states where its own credentials are.
  #
  # The password is its database role's; the server reads every machine's to
  # keep the roles in step. The key is the certificate's, and belongs to the
  # user running the push, so it sits with that machine's other user secrets.
  #
  # A password ends up in a connection URL, so generate it with
  # `openssl rand -hex 32`. One containing `/`, `#`, `?` or `:` is parsed as a
  # port or a path and the connection fails.
  passwordFile = hostname: "agentsview-postgres/${hostname}.yaml";
  passwordSecret = "password";

  privateKeyFile = hostname: "${hostname}/user-agentsview.yaml";
  privateKeySecret = "agentsview_client_key";

  # A secret is named after the machine it belongs to, so one host reading
  # several of them keeps them apart.
  passwordSecretFor = hostname: "agentsview_password_${hostname}";

  # openssl writes the curve out in full by default and Go rejects a key like
  # that, so the named-curve encoding has to be asked for.
  generateCertificate = hostname: ''
    openssl req -x509 -newkey ec \
      -pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve \
      -nodes -days 36500 -subj "/CN=${hostname}" \
      -keyout ${hostname}-agentsview.key \
      -out hosts/${hostname}/agentsview.pem
  '';
in {
  inherit
    certificatePath
    clientProfile
    generateCertificate
    hasCertificate
    passwordFile
    passwordSecret
    passwordSecretFor
    privateKeyFile
    privateKeySecret
    profileSettings
    pushes
    role
    serverDefaults
    serverProfile
    serverSettings
    syncingHosts
    ;
}
