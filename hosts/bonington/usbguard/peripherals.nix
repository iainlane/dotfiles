{
  dotfiles.usbguard.staticRules = {
    "30-peripherals.conf" = [
      # Focusrite Scarlett 2i2 4th Gen audio interface.
      {
        target = "allow";
        id = "1235:8219";
        serial = "S2AR8Q3350C05D";
      }
      {
        target = "allow";
        id = "0fd9:0080";
        hash = "oh6NVjQsy6NgU63thyxv4KlRKdIMWpq/CCwhzZv5jMY=";
        label = "Stream Deck MK.2";
      }
      {
        target = "allow";
        id = "0fd9:00a1";
        hash = "b5XEsKNcGWquWeGXj1HFPvxxtN17AU9t/hojdsTOfhY=";
        label = "Cam Link 4K";
      }
      {
        target = "allow";
        id = "3434:d030";
        hash = "gfm9dUg3k4ERginO0CR4zhvckjZ/kZ+to/WtGxgHdZ8=";
        label = "Keychron Link";
      }
      {
        target = "allow";
        id = "046d:085c";
        hash = "UPp89eqpW1t3DXAuv+PUzer6ajP2wCPSXVDoTHwFuYQ=";
        label = "C922 Pro Stream Webcam";
      }
    ];
  };
}
