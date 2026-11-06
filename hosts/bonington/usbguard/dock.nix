{
  dotfiles.usbguard.staticRules = {
    "10-dock.conf" = [
      # ThinkPad Universal Thunderbolt 4 Dock (40B00135UK): upstream USB 2.0 hub.
      {
        target = "allow";
        id = "17ef:30ba";
        hash = "zgRuBkoOVD6C344a7PjQ3uuHeE3wzslavAxqm8ENJRI=";
        label = "V1003";
      }
      # Intel Thunderbolt controller's upstream USB 3.0 hub.
      {
        target = "allow";
        id = "8087:0b40";
        hash = "DUBZOlz8w3hA6Z3XcyG1XyGcKn/1zRj640NOV9KO1W8=";
        label = "USB3.0 Hub";
      }
      {
        target = "allow";
        id = "17ef:30b4";
        hash = "BE7ajZfe7sV1IyiMukmy3hpqRhRvZuXayMHWDTbmP+Q=";
        label = "ThinkPad Thunderbolt 4 Dock MCU Controller2";
      }
      # Dock management information and USB-C billboard interfaces.
      {
        target = "allow";
        id = "17ef:30b5";
        hash = "2r1Gp0+uqi2irrCRnRrv1/9/ub/2mTppUCQJgG24SuQ=";
        label = "40B0";
      }
      {
        target = "allow";
        id = "17ef:30b7";
        hash = "MSZIdQbDgx5JJUvScdV7UtVvchpkKVBF/lQ7dbQQA3w=";
        label = "USB2.0 Hub";
      }
      {
        target = "allow";
        id = "17ef:30b6";
        hash = "7N/ISZP75Amsmujiu/dvz1P5dtvJMgrWd7RyEWd0Olg=";
        label = "USB3.1 Hub";
      }
      {
        target = "allow";
        id = "17ef:30b9";
        hash = "CHvaSdGRo7fQPiy8kXZFRCoN+rookwhgA/uQEOAaujY=";
        label = "USB2.0 Hub";
      }
      {
        target = "allow";
        id = "17ef:30b8";
        hash = "8JnDYgqysiD83/B2LD7C95zJ/bdf681WX6Lp8kDMLVA=";
        label = "USB3.1 Hub";
      }
      {
        target = "allow";
        id = "0bda:8153";
        hash = "2oO8TIZE3iDREKgjzrJwgoEjcXVBMG32fgIO4yKRJKo=";
        label = "Realtek LAN";
      }
      {
        target = "allow";
        id = "17ef:30bb";
        hash = "ou3vbptyzD+cLeIXpyiQHz8KQ5t5oY9FLGOwGapZMz4=";
        label = "ThinkPad Thunderbolt 4 Dock USB Audio";
      }
    ];
  };
}
