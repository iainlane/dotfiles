{
  services.gpg-agent = {
    enable = true;

    enableSshSupport = false;
  };

  services.ssh-agent = {
    enable = true;
  };
}
