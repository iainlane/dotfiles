let
  halls = import ../../lib/halls.nix;
in {
  hostname = "bonington";
  os = "nixos";
  arch = "x86_64";
  channel = "stable";
  stateVersion = "25.05";
  motd = halls.bonington;
  profiles = [
    "base"
    "builder"
    {
      desktop.usbguardStaticRules."10-scarlett.conf" = ''
        allow id 1235:8219 serial "S2AR8Q3350C05D"
      '';
    }
    "development"
    "cloud"
    "containers"
    "inference"
    "work"
  ];

  homeModule = _: {
    dotfiles.git.signing = {
      key = "~/.ssh/id_ed25519";
      format = "ssh";
    };

    programs.git.settings.user.email = "iain.lane@chainguard.dev";
  };
}
