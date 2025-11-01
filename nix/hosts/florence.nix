{
  hostname = "florence.local";
  os = "linux";
  arch = "x86_64";
  profiles = [
    "base"
    "desktop"
    "development"
    "cloud"
    "work"
  ];

  homeModule = _: {
    # Work git identity (override the personal defaults)
    programs.git = {
      settings.user.email = "iain@grafana.com";
      signing.key = "AB2F5FB2C0B9FCE22B9D773B3B590AA273354714";
    };
  };
}
