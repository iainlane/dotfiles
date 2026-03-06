_: {
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
      "com.apple.finder" = {
        _FXSortFoldersFirst = true;
        # SCcf = "Search Current Folder"
        FXDefaultSearchScope = "SCcf";
        ShowExternalHardDrivesOnDesktop = true;
        ShowHardDrivesOnDesktop = false;
        ShowMountedServersOnDesktop = true;
        ShowRemovableMediaOnDesktop = true;
      };
      # Prevent Photos from opening automatically
      "com.apple.ImageCapture".disableHotPlug = true;
      "com.apple.screencapture" = {
        location = "~/Pictures/Screenshots";
        type = "png";
      };
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
      # Turn on App Store auto-update.
      "com.apple.commerce".AutoUpdate = true;
      # Enable three-finger horizontal swipe between full-screen apps (2 = swipe between pages).
      "com.apple.driver.AppleBluetoothMultitouch.trackpad" = {
        TrackpadThreeFingerHorizSwipeGesture = 2;
      };
      # Enable three finger horizontal swipe between full screen apps (2 = swipe between pages)
      "com.apple.AppleMultitouchTrackpad" = {
        TrackpadThreeFingerHorizSwipeGesture = 2;
      };
    };
    NSGlobalDomain = {
      # Prefer 24-hour time and keep the system in sync with the light/dark
      # cycle automatically.
      AppleICUForce24HourTime = true;
      AppleInterfaceStyleSwitchesAutomatically = true;
      AppleMeasurementUnits = "Centimeters";
      AppleMetricUnits = 1;
      AppleTemperatureUnit = "Celsius";
      # Keep keyboard repeat snappy.
      InitialKeyRepeat = 25;
      KeyRepeat = 5;
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
      FXEnableExtensionChangeWarning = false;
      FXPreferredViewStyle = "Nlsv";
      AppleShowAllExtensions = true;
      AppleShowAllFiles = true;
      QuitMenuItem = true;
      ShowPathbar = true;
      ShowStatusBar = true;
    };
    menuExtraClock = {
      ShowAMPM = true;
      # 0 = show date when space allows, 1 = always show, 2 = never show
      ShowDate = 0;
      ShowDayOfWeek = true;
      ShowSeconds = false;
    };
    screensaver = {
      # Require a password five minutes after the screensaver kicks in.
      askForPassword = true;
      askForPasswordDelay = 300;
    };
    # smb.NetBIOSName = hostname;
    trackpad = {
      Clicking = true;
      # Enable two finger right click
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
