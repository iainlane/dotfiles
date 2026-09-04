# The host's own address on the LAN, taken from the addresses the networks
# carry.
#
# A container port published to every address is reachable from anything that
# can route to this host, which for a host holding a routed public address means
# the internet. A port published to this address is reachable from the LAN
# only.
{
  config,
  lib,
  ...
}: let
  addressesOf = network:
    network.address
    ++ lib.toList (network.networkConfig.Address or []);

  withoutPrefixLength = address: lib.head (lib.splitString "/" address);

  # The three ranges RFC 1918 sets aside, which is what a LAN address comes
  # from. An address with any other shape, an IPv6 one included, splits into
  # something other than four decimal octets.
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
      The one private IPv4 address the networks carry, without its prefix
      length. A service binds a published container port to it so the port is
      reachable from the LAN and from nowhere else.

      A host whose networks carry no private IPv4 address, or more than one,
      leaves this undefined and fails an assertion naming the addresses found.
    '';
  };

  options.privateAddresses = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    description = ''
      Every private IPv4 address the networks carry, which the enclosing
      configuration asserts there is exactly one of.
    '';
  };

  config = {
    inherit privateAddresses;

    lanAddress = lib.mkIf (lib.length privateAddresses == 1) (lib.head privateAddresses);
  };
}
