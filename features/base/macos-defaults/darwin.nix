{
  security.pam.services.sudo_local.touchIdAuth = true;

  system.defaults = {
    CustomUserPreferences = {
      "com.apple.AdLib" = {
        allowApplePersonalizedAdvertising = false;
      };
      "com.apple.desktopservices" = {
        DSDontWriteNetworkStores = true;
        DSDontWriteUSBStores = true;
      };
      # Stop Photos opening when a camera or a phone is plugged in.
      "com.apple.ImageCapture".disableHotPlug = true;
      "com.apple.SoftwareUpdate" = {
        AutomaticCheckEnabled = true;
        # Check for software updates daily (1 = daily).
        ScheduleFrequency = 1;
        # Do not download new updates automatically (0 = disabled).
        AutomaticDownload = 0;
        # Install system data files and security updates (1 = enabled).
        CriticalUpdateInstall = 1;
      };
      "com.apple.TimeMachine".DoNotOfferNewDisksForBackup = true;
      "com.apple.commerce".AutoUpdate = true;
      # A three-finger horizontal swipe moves between full-screen apps
      # (2 = swipe between pages). Set for the Bluetooth and the built-in
      # trackpad drivers.
      "com.apple.driver.AppleBluetoothMultitouch.trackpad" = {
        TrackpadThreeFingerHorizSwipeGesture = 2;
      };
      "com.apple.AppleMultitouchTrackpad" = {
        TrackpadThreeFingerHorizSwipeGesture = 2;
      };
    };
    NSGlobalDomain = {
      AppleICUForce24HourTime = true;
      AppleInterfaceStyleSwitchesAutomatically = true;
      AppleMeasurementUnits = "Centimeters";
      AppleMetricUnits = 1;
      AppleTemperatureUnit = "Celsius";
      InitialKeyRepeat = 15;
      KeyRepeat = 2;
      NSAutomaticCapitalizationEnabled = false;
      NSAutomaticDashSubstitutionEnabled = true;
      NSAutomaticPeriodSubstitutionEnabled = false;
      NSAutomaticQuoteSubstitutionEnabled = true;
      NSAutomaticSpellingCorrectionEnabled = false;
      NSNavPanelExpandedStateForSaveMode = true;
      NSNavPanelExpandedStateForSaveMode2 = true;
      "com.apple.swipescrolldirection" = false;
    };
    SoftwareUpdate = {
      AutomaticallyInstallMacOSUpdates = false;
    };
    finder = {
      _FXShowPosixPathInTitle = true;
      _FXSortFoldersFirst = true;
      # SCcf = "Search Current Folder"
      FXDefaultSearchScope = "SCcf";
      FXEnableExtensionChangeWarning = false;
      FXPreferredViewStyle = "Nlsv";
      AppleShowAllExtensions = true;
      AppleShowAllFiles = true;
      QuitMenuItem = true;
      ShowExternalHardDrivesOnDesktop = true;
      ShowHardDrivesOnDesktop = false;
      ShowMountedServersOnDesktop = true;
      ShowPathbar = true;
      ShowRemovableMediaOnDesktop = true;
      ShowStatusBar = true;
    };
    screencapture = {
      location = "~/Pictures/Screenshots";
      type = "png";
    };
    menuExtraClock = {
      ShowAMPM = true;
      # 0 = show date when space allows, 1 = always show, 2 = never show
      ShowDate = 0;
      ShowDayOfWeek = true;
      ShowSeconds = false;
    };
    screensaver = {
      # The delay is in seconds: ask for a password five minutes after the
      # screensaver starts.
      askForPassword = true;
      askForPasswordDelay = 300;
    };
    # smb.NetBIOSName = hostname;
    trackpad = {
      Clicking = true;
      TrackpadRightClick = true;
    };
    dock = {
      autohide = true;
      magnification = true;
      largesize = 65;
      tilesize = 66;
      expose-group-apps = true;
      wvous-tl-corner = 2;
      wvous-br-corner = 14;
    };
  };
}
