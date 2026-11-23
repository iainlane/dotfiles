{
  imports = [./sudo-rules.nix];

  environment.etc."sudoers.d/99-no-pwfeedback" = {
    text = "Defaults !pwfeedback\n";
    mode = "0440";
  };
}
