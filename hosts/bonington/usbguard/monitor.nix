{
  dotfiles.usbguard.staticRules = {
    "20-monitor.conf" = [
      # Dell U4919DW monitor's TI TUSB8044 USB 2.0 hub.
      {
        target = "allow";
        id = "0451:8442";
        hash = "EX/pM2wRM71HMzspD6rDj6voRFqk9GrqIrZjbCfUeAc=";
      }
      # Dell U4919DW monitor's TI TUSB8044 USB 3.0 hub.
      {
        target = "allow";
        id = "0451:8440";
        hash = "8/S/8YfJYtcyx0Y/v9FFFQgx8+OJvezHDc7mrLb87V4=";
      }
      # TI TUSB8042 USB 3.0 hub, downstream of the TUSB8044.
      {
        target = "allow";
        id = "0451:8240";
        hash = "RusbR0U/RVyqzyu9V9VS+qyIJJdY8GotwBm85u/WL/I=";
      }
      # TI TUSB8042 USB 2.0 hub, downstream of the TUSB8044.
      {
        target = "allow";
        id = "0451:8242";
        hash = "6zPC+x/hNgYDO6/xSTY+SPQwxF39wv+i5gz6o9uZQbI=";
      }
      # Monitor's TUSB8044 internal HID-to-I2C programming interface.
      {
        target = "allow";
        id = "0451:82ff";
        hash = "ucUfwXcVj3jpSSqfTWanHcaUyFppBEeR9o3KILYoYyU=";
      }
    ];
  };
}
