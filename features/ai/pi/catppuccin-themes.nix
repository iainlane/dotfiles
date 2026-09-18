{
  lib,
  catppuccinPaletteSource,
  accent,
}: let
  paletteFile = catppuccinPaletteSource + "/palette.json";
  palette = builtins.fromJSON (builtins.readFile paletteFile);

  hexVars = flavor:
    lib.mapAttrs (_: c: c.hex) palette.${flavor}.colors;

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

  # Latte's yellow foreground text falls below WCAG AA contrast on its base.
  # Catppuccin's bat and delta themes also use peach for this purpose.
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

  flavors = builtins.filter (k: k != "version") (lib.attrNames palette);
in {
  themes = lib.genAttrs flavors mkTheme;
  inherit flavors;
}
