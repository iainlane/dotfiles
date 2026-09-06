# The host's own address on the LAN, taken from the addresses configured on
# its networks.
#
# Binding a published container port to this private address keeps it from
# listening on the host's public addresses. Routing and firewall rules still
# determine which clients can reach it.
{
  config,
  lib,
  ...
}: let
  addressesOf = network:
    network.address
    ++ lib.toList (network.networkConfig.Address or []);

  withoutPrefixLength = address: lib.head (lib.splitString "/" address);

  # A LAN address comes from one of the three ranges RFC 1918 sets aside.
  # Require four dot-separated components first, which rules out an IPv6
  # address, then check the first two components against those ranges.
  isPrivateIPv4 = address: let
    octets = lib.splitString "." address;

    inRange = let
      first = lib.toIntBase10 (lib.elemAt octets 0);
      second = lib.toIntBase10 (lib.elemAt octets 1);
    in
      first
      == 10
      || (first == 172 && second >= 16 && second <= 31)
      || (first == 192 && second == 168);
  in
    lib.length octets == 4 && inRange;

  addresses =
    map withoutPrefixLength
    (lib.concatMap addressesOf (lib.attrValues config.systemd.network.networks));

  privateAddresses = lib.filter isPrivateIPv4 addresses;
in {
  options.lanAddress = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    description = ''
      The single private IPv4 address configured on the networks, without its
      prefix length. Services bind published container ports to this address
      to avoid listening on public addresses. Routing and firewall rules
      determine which clients can reach those ports.

      A host whose networks have no private IPv4 address, or more than one,
      leaves this undefined and fails an assertion naming the addresses found.
    '';
  };

  options.privateAddresses = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    description = ''
      All private IPv4 addresses configured on the networks. The enclosing
      configuration asserts that this list contains exactly one address.
    '';
  };

  config = {
    inherit privateAddresses;

    lanAddress = lib.mkIf (lib.length privateAddresses == 1) (lib.head privateAddresses);
  };
}
