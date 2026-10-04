{
  testers,
  larapaper-image,
}: let
  libraries = larapaper-image.larapaper.webLibraries.sources;
in
  testers.runNixOSTest {
    name = "larapaper";
    nodes.machine = {pkgs, ...}: {
      virtualisation = {
        podman.enable = true;
        memorySize = 4096;
        diskSize = 16384;
      };
      environment.systemPackages = [pkgs.curl pkgs.openssl];
      environment.etc."larapaper-smoke.php".source = ./smoke.php;
    };
    testScript = ''
      start_all()
      machine.succeed("ip address add 192.168.50.2/32 dev lo")
      machine.succeed("podman load -i ${larapaper-image}")
      machine.succeed("printf 'APP_KEY=base64:%s\\n' $(openssl rand -base64 32) > /run/larapaper.env")
      machine.succeed("podman run -d --name larapaper --network host --cap-drop ALL --security-opt no-new-privileges --env-file /run/larapaper.env -e APP_URL=http://192.168.50.2:8080 -v larapaper-database:/var/lib/larapaper/database -v larapaper-storage:/var/lib/larapaper/storage/app/public/images/generated localhost/larapaper:${larapaper-image.imageTag}")
      machine.wait_until_succeeds("curl --fail http://127.0.0.1:8080/up")
      for path in [
          "/login",
          "/css/2.3.7/plugins.css",
          "/css/${larapaper-image.trmnl-framework.version}/plugins.css",
          "/css/${larapaper-image.trmnl-framework.version}/themes/dark-theme.css",
          "/js/${larapaper-image.trmnl-framework.version}/plugins.js",
          "/js/highcharts/${libraries.highcharts.version}/highcharts.js",
          "/js/highcharts/${libraries.highcharts.version}/pattern-fill.js",
          "/js/chartkick/${libraries.chartkick.version}/chartkick.min.js",
          "/js/maplibre-gl/${libraries.maplibre-gl.version}/maplibre-gl.js",
          "/js/maplibre-gl/${libraries.maplibre-gl.version}/maplibre-gl.css",
          "/fonts/TRMNL12-Regular.woff2",
      ]:
          machine.succeed(f"curl --fail --silent http://127.0.0.1:8080{path} > /dev/null")
      machine.succeed("podman cp /etc/larapaper-smoke.php larapaper:/tmp/smoke.php")
      machine.succeed("podman exec larapaper php /tmp/smoke.php")
      machine.succeed("podman exec larapaper trmnl-liquid-cli --template '{{ value | upcase }}' --context '{\"value\":\"local\"}' | grep -x LOCAL")
      machine.succeed("podman exec larapaper cp /tmp/larapaper-smoke.png /var/lib/larapaper/storage/app/public/images/generated/package-probe.png")
      machine.succeed("podman stop larapaper && podman start larapaper")
      machine.wait_until_succeeds("curl --fail --silent http://127.0.0.1:8080/up")
      machine.succeed("curl --fail --silent http://127.0.0.1:8080/storage/images/generated/package-probe.png > /tmp/probe.png")
      machine.succeed("test -s /tmp/probe.png")
    '';
  }
