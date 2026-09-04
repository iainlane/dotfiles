# Render the Catppuccin palette as Pi theme JSON.
#
# The palette data comes from the upstream `catppuccin/palette` repo via the
# `catppuccin-palette` flake input, so the colour values stay in sync with
# the rest of the ecosystem without IFD or vendored JSON.
{
  lib,
  catppuccinPaletteSource,
  accent,
}: let
  paletteFile = catppuccinPaletteSource + "/palette.json";
  palette = builtins.fromJSON (builtins.readFile paletteFile);

  # Each flavor entry has the shape:
  #   { name; emoji; order; dark; colors = { rosewater = { hex; rgb; hsl; }; ... }; }
  # Pi only needs the hex strings.
  hexVars = flavor:
    lib.mapAttrs (_: c: c.hex) palette.${flavor}.colors;

  # Role-to-palette-name mapping shared by every flavor. `accent` follows
  # the user's `config.catppuccin.accent` preference; everything else
  # references named palette entries directly.
  baseRoleMap = {
    inherit accent;
    border = "surface2";
    borderAccent = "blue";
    borderMuted = "surface0";
    success = "green";
    error = "red";
    warning = "yellow";
    muted = "subtext0";
    dim = "overlay0";
    text = "text";
    thinkingText = "overlay2";

    selectedBg = "surface0";
    userMessageBg = "mantle";
    userMessageText = "text";
    customMessageBg = "surface0";
    customMessageText = "text";
    customMessageLabel = "mauve";
    toolPendingBg = "mantle";
    toolSuccessBg = "surface0";
    toolErrorBg = "surface0";
    toolTitle = "sapphire";
    toolOutput = "subtext1";

    mdHeading = "mauve";
    mdLink = "blue";
    mdLinkUrl = "sapphire";
    mdCode = "teal";
    mdCodeBlock = "text";
    mdCodeBlockBorder = "surface1";
    mdQuote = "subtext0";
    mdQuoteBorder = "surface1";
    mdHr = "surface1";
    mdListBullet = "peach";

    toolDiffAdded = "green";
    toolDiffRemoved = "red";
    toolDiffContext = "overlay1";

    syntaxComment = "overlay1";
    syntaxKeyword = "mauve";
    syntaxFunction = "blue";
    syntaxVariable = "text";
    syntaxString = "green";
    syntaxNumber = "peach";
    syntaxType = "yellow";
    syntaxOperator = "sky";
    syntaxPunctuation = "overlay2";

    thinkingOff = "surface1";
    thinkingMinimal = "overlay0";
    thinkingLow = "sapphire";
    thinkingMedium = "blue";
    thinkingHigh = "mauve";
    thinkingXhigh = "pink";
    bashMode = "peach";
  };

  # Catppuccin Latte's yellow `#df8e1d` against the cream base `#eff1f5`
  # falls under WCAG AA. Swap roles that show yellow as foreground text
  # to peach `#fe640b`, which catppuccin/delta and catppuccin/bat use for
  # the same purpose on Latte.
  flavorRoleOverrides = {
    latte = {
      warning = "peach";
      syntaxType = "peach";
    };
  };

  roleMapFor = flavor:
    baseRoleMap // (flavorRoleOverrides.${flavor} or {});

  mkTheme = flavor: {
    "$schema" = "https://raw.githubusercontent.com/badlogic/pi-mono/main/packages/coding-agent/src/modes/interactive/theme/theme-schema.json";
    name = "catppuccin-${flavor}";
    vars = hexVars flavor;
    colors = roleMapFor flavor;
    export = {
      pageBg = "base";
      cardBg = "mantle";
      infoBg = "surface0";
    };
  };

  # The palette JSON's top-level has "version" alongside the flavor keys.
  flavors = builtins.filter (k: k != "version") (lib.attrNames palette);
in {
  themes = lib.genAttrs flavors mkTheme;
  inherit flavors;
}
