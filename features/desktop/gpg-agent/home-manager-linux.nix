{pkgs, ...}: {
  services.gpg-agent.pinentry = {
    package = pkgs.pinentry-gnome3;
    program = "pinentry-gnome3";
  };
}
