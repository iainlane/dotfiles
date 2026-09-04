{
  dotfiles.ssh.settings = {
    cripps = {
      HostName = "cripps.orangesquash.org.uk";
      User = "laney";
    };

    os = {
      HostName = "cripps.orangesquash.org.uk";
      User = "laney";
    };
  };

  programs.git.settings.sendemail = {
    smtpencryption = "tls";
    smtpserver = "mail.messagingengine.com";
    smtpuser = "laney@fastmail.fm";
    smtpserverport = 587;
    suppresscc = "self";
  };
}
