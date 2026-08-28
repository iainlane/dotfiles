{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  common = import ./common.nix;

  palette =
    (builtins.fromJSON (builtins.readFile "${inputs.catppuccin-palette}/palette.json"))
    .${config.catppuccin.flavor}
    .colors;
in {
  # Stable home-manager branched before the voxtype module existed; use the
  # module from the unstable input on both channels.
  disabledModules = ["services/voxtype.nix"];
  imports = [(import "${inputs.home-manager}/modules/services/voxtype.nix")];

  assertions = [
    {
      assertion = pkgs.voxtype-osd-gtk4.version == pkgs.voxtype-onnx.version;
      message = "voxtype-osd-gtk4 (${pkgs.voxtype-osd-gtk4.version}) and voxtype-onnx (${pkgs.voxtype-onnx.version}) must be the same version; their OSD socket protocol is not stable across versions.";
    }
  ];

  home.packages = [pkgs.eitype];

  services.voxtype = {
    enable = true;

    package = pkgs.voxtype-onnx;

    # This replaces the unit's PATH, so include the module's own entries.
    # eitype has to come from the unit's PATH because the voxtype wrapper's
    # bundled typing backends do not include it, and the daemon spawns the
    # `voxtype-osd` launcher (shipped with the daemon package) and the GTK4
    # frontend by searching PATH.
    environment.PATH = lib.makeBinPath [
      pkgs.coreutils
      pkgs.eitype
      pkgs.voxtype-onnx
      pkgs.voxtype-osd-gtk4
      pkgs.which
    ];

    settings = lib.recursiveUpdate (common.settings pkgs) {
      # The desktop manages the binding through the XDG GlobalShortcuts
      # portal: hold to record, release to transcribe. The desktop's saved
      # binding is authoritative; change it in the desktop's own shortcut
      # settings.
      hotkey = {
        enabled = true;
        backend = "portal";
        mode = "push_to_talk";
      };

      output = {
        # The default driver chain starts with wtype, which needs the
        # virtual-keyboard Wayland protocol that Mutter does not implement.
        # eitype types through the libei portal, which GNOME supports.
        driver_order = ["eitype" "clipboard"];

        # At the zero-delay default, eitype silently drops the tail of longer
        # dictations and still reports success, so the clipboard fallback
        # never engages (upstream issue #552, reproduced on GNOME).
        type_delay_ms = 1;

        notification.on_transcription = false;
      };
    };
  };

  # The GTK4 OSD paints with Cairo and is not themeable through GTK CSS. It
  # reads its colours only from this Omarchy theme file; map the six keys it
  # parses to the host's catppuccin flavour.
  xdg.configFile."omarchy/current/theme/colors.toml".text = ''
    background = "${palette.base.hex}"
    foreground = "${palette.text.hex}"
    accent     = "${palette.blue.hex}"
    color1     = "${palette.red.hex}"
    color2     = "${palette.green.hex}"
    color3     = "${palette.yellow.hex}"
  '';
}
