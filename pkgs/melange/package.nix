{melange}:
melange.overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.53.0";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-UYP37ecJBGs/yfTdC5Veg09tNzq2oy1X+Idgv0NWR6s=";};
  vendorHash = "sha256-Pb9SeGhhwlpkUkQDyj3PomJ58UlfebQFkZfBonL5Ho8=";

  passthru = (prevAttrs.passthru or {}) // {updateScript = ./update.sh;};
})
