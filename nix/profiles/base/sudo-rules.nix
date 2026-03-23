# Both NixOS and system-manager generate /etc/sudoers via security.sudo.
# The default only includes %wheel; add %sudo so Debian/Ubuntu hosts
# (which use the sudo group) keep working.
[
  {
    groups = ["sudo"];
    commands = [
      {
        command = "ALL";
        options = ["SETENV"];
      }
    ];
  }
]
