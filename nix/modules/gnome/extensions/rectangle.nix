{pkgs, ...}: let
  bindingKeys = [
    "tile-quarter-top-left"
    "tile-quarter-top-right"
    "tile-quarter-bottom-left"
    "tile-quarter-bottom-right"
    "tile-quarter-centered"
    "tile-fourth-first"
    "tile-fourth-second"
    "tile-fourth-third"
    "tile-fourth-fourth"
    "tile-third-first"
    "tile-third-second"
    "tile-third-third"
    "tile-sixth-top-left"
    "tile-sixth-top-center"
    "tile-sixth-top-right"
    "tile-sixth-bottom-left"
    "tile-sixth-bottom-center"
    "tile-sixth-bottom-right"
    "tile-ninth-top-left"
    "tile-ninth-top-center"
    "tile-ninth-top-right"
    "tile-ninth-middle-left"
    "tile-ninth-middle-center"
    "tile-ninth-middle-right"
    "tile-ninth-bottom-left"
    "tile-ninth-bottom-center"
    "tile-ninth-bottom-right"
    "tile-half-center-vertical"
    "tile-half-center-horizontal"
    "tile-half-left"
    "tile-half-right"
    "tile-half-top"
    "tile-half-bottom"
    "tile-two-thirds-left"
    "tile-two-thirds-center"
    "tile-two-thirds-right"
    "tile-three-fourths-left"
    "tile-three-fourths-right"
    "tile-center"
    "tile-maximize"
    "tile-maximize-almost"
    "tile-maximize-height"
    "tile-maximize-width"
    "tile-stretch-top"
    "tile-stretch-bottom"
    "tile-stretch-left"
    "tile-stretch-right"
    "tile-stretch-step-bottom-left"
    "tile-stretch-step-bottom"
    "tile-stretch-step-bottom-right"
    "tile-stretch-step-left"
    "tile-stretch-step-right"
    "tile-stretch-step-top-left"
    "tile-stretch-step-top"
    "tile-stretch-step-top-right"
    "tile-move-bottom-left"
    "tile-move-bottom"
    "tile-move-bottom-right"
    "tile-move-left"
    "tile-move-right"
    "tile-move-top-left"
    "tile-move-top"
    "tile-move-top-right"
    "tile-move-to-monitor-top"
    "tile-move-to-monitor-bottom"
    "tile-move-to-monitor-left"
    "tile-move-to-monitor-right"
    "tile-shrink"
    "tile-expand"
  ];

  bindings =
    (builtins.listToAttrs (map (name: {
        inherit name;
        value = [""];
      })
      bindingKeys))
    // {
      tile-fourth-first = ["<Control><Super>Left"];
      tile-half-center-vertical = ["<Control><Super>Up"];
      tile-fourth-fourth = ["<Control><Super>Right"];
      tile-half-left = ["<Control><Alt><Super>Left"];
      tile-half-right = ["<Control><Alt><Super>Right"];
    };
in {
  package = pkgs.gnomeExtensions.rectangle;

  dconfSettings = {
    "org/gnome/shell/extensions/rectangle" =
      bindings
      // {
        padding-inner = 1;
        padding-outer = 0;
        show-icon = false;
      };
  };
}
