{
  inputs,
  pkgs,
  servers,
  skillPackages,
  skills,
  archiveCli,
}: let
  inherit (pkgs) lib;
  runtimes = pkgs.librechat-code.runtimes;
  runner = pkgs.librechat-code.runner;
  workspaceUid = 200000;
  workspaceGid = 200000;
  tools = pkgs.buildEnv {
    name = "librechat-guest-tools";
    paths = (with pkgs; [bash coreutils curl findutils git gh gnugrep gnused jq nodejs_24 ripgrep cacert]) ++ [runtimes.bun runtimes.python314 archiveCli] ++ skillPackages;
    pathsToLink = ["/bin"];
  };
  proxyEnvironment = {
    HOME = "/mnt/data";
    PATH = "/usr/bin:/bin";
    HTTP_PROXY = "http://10.0.2.100:3128";
    HTTPS_PROXY = "http://10.0.2.100:3128";
    http_proxy = "http://10.0.2.100:3128";
    https_proxy = "http://10.0.2.100:3128";
    NO_PROXY = "localhost,127.0.0.1,::1,10.0.2.101,10.0.2.102";
    no_proxy = "localhost,127.0.0.1,::1,10.0.2.101,10.0.2.102";
    NODE_USE_ENV_PROXY = "1";
    SSL_CERT_FILE = "/run/librechat-guest/ca-bundle.crt";
    REQUESTS_CA_BUNDLE = "/run/librechat-guest/ca-bundle.crt";
    CURL_CA_BUNDLE = "/run/librechat-guest/ca-bundle.crt";
    GIT_SSL_CAINFO = "/run/librechat-guest/ca-bundle.crt";
    NODE_EXTRA_CA_CERTS = "/run/librechat-guest/ca-bundle.crt";
    GH_TOKEN = "iron-github-placeholder";
    XDG_DATA_HOME = "/usr/share";
  };
  runtime = language: package: version: executable: aliases:
    pkgs.runCommand "librechat-${language}-runtime" {} ''
      directory="$out/${language}/${version}"
      mkdir -p "$directory"
      touch "$directory/.package-installed"
      cp ${pkgs.writeText "pkg-info.json" (builtins.toJSON {inherit language version aliases;})} "$directory/pkg-info.json"
      cp ${pkgs.writeText "runtime.env" (lib.concatStringsSep "\n" (lib.mapAttrsToList (key: value: "${key}=${value}") proxyEnvironment))} "$directory/.env"
      cat > "$directory/run" <<'SCRIPT'
      #!${lib.getExe pkgs.bash}
      exec ${package}/bin/${executable} "$@"
      SCRIPT
      chmod +x "$directory/run"
    '';
  packages = pkgs.symlinkJoin {
    name = "librechat-code-runtimes";
    paths = [
      (runtime "bash" runtimes.bash (builtins.replaceStrings ["p"] ["."] runtimes.bash.version) "bash" ["sh"])
      (runtime "node" runtimes.nodejs_24 runtimes.nodejs_24.version "node" ["nodejs"])
      (runtime "python" runtimes.python314 runtimes.python314.python.version "python3" ["py"])
      (runtime "bun-js" runtimes.bun runtimes.bun.version "bun" ["javascript" "js" "bun"])
      (runtime "bun-ts" runtimes.bun runtimes.bun.version "bun" ["typescript" "ts"])
    ];
  };
  jail = pkgs.writeText "librechat-nsjail.cfg" ''
    name: "librechat-conversation"
    mode: ONCE
    cwd: "/mnt/data"
    no_pivotroot: true
    keep_env: false
    keep_caps: false
    clone_newnet: false
    clone_newuser: true
    clone_newns: true
    clone_newpid: true
    clone_newipc: true
    clone_newuts: true
    clone_newcgroup: true
    mount_proc: false
    mount { src: "/usr" dst: "/usr" is_bind: true rw: false }
    mount { src: "/etc/gitconfig" dst: "/etc/gitconfig" is_bind: true rw: false }
    mount { src: "/nix/store" dst: "/nix/store" is_bind: true rw: false }
    mount { src: "/run/librechat-guest" dst: "/run/librechat-guest" is_bind: true rw: false }
    mount { src: "/dev/null" dst: "/dev/null" is_bind: true rw: false }
    mount { src: "/dev/urandom" dst: "/dev/urandom" is_bind: true rw: false }
    mount { src: "/dev/zero" dst: "/dev/zero" is_bind: true rw: false }
    mount { dst: "/tmp" fstype: "tmpfs" rw: true options: "size=128m" }
    mount { dst: "/proc" fstype: "proc" rw: false }
  '';
  specification = pkgs.writeText "librechat-guest.json" (builtins.toJSON {
    runner = lib.getExe runner;
    mcpProxy = lib.getExe pkgs.mcp-proxy;
    mcpEnvironment = proxyEnvironment;
    mcpConfiguration = pkgs.writeText "librechat-mcp.json" (builtins.toJSON {mcpServers = servers;});
    caBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    systemctl = lib.getExe' pkgs.systemd "systemctl";
    systemdRun = lib.getExe' pkgs.systemd "systemd-run";
    workspace = {
      uid = workspaceUid;
      gid = workspaceGid;
      mkdir = lib.getExe' pkgs.coreutils "mkdir";
      certutil = lib.getExe' pkgs.nss.tools "certutil";
    };
    runnerEnvironment = {
      PATH = lib.makeBinPath [pkgs.bash pkgs.coreutils pkgs.gnutar pkgs.gzip];
      NSJAIL_CONFIG = toString jail;
      SANDBOX_PACKAGES_DIRECTORY = toString packages;
      SANDBOX_SESSION_WORKSPACE_ENABLED = "true";
      SANDBOX_REQUIRE_EGRESS_MANIFEST = "true";
      SANDBOX_EXECUTION_MANIFEST_BODY_HASH_LEGACY_GRACE_SECONDS = "0";
      SANDBOX_DISABLE_NETWORKING = "false";
      SANDBOX_USE_CGROUPV2 = "true";
      EGRESS_GATEWAY_URL = "http://10.0.2.101:3190";
      SANDBOX_MAX_CONCURRENT_JOBS = "1";
      SANDBOX_JOB_UID_BASE = toString workspaceUid;
      SANDBOX_JOB_GID_BASE = toString workspaceGid;
      SANDBOX_LOG_LEVEL = "INFO";
    };
  });
  system = inputs.nixpkgs.lib.nixosSystem {
    inherit pkgs;
    modules = [
      ({
        config,
        modulesPath,
        ...
      }: {
        imports = ["${modulesPath}/profiles/minimal.nix"];

        system = {
          stateVersion = "26.05";

          activationScripts.guestTools.text = ''
            mkdir -p /usr/bin /usr/lib /usr/lib64 /usr/local/bin /usr/share/gh/extensions/gh-stack
            for tool in ${tools}/bin/*; do
              ln -sfn "$tool" "/usr/bin/$(basename "$tool")"
            done
            ln -sfn ${runner}/bin/spec-guard /usr/local/bin/spec-guard
            ln -sfn ${skills} /usr/share/agent-skills
            ln -sfn ${pkgs.gh-stack}/bin/gh-stack /usr/share/gh/extensions/gh-stack/gh-stack
          '';

          build.librechatImage = let
            rootImage = pkgs.callPackage "${modulesPath}/../lib/make-ext4-fs.nix" {
              storePaths = [config.system.build.toplevel];
              volumeLabel = "nixos";
              populateImageCommands = "mkdir -p files/etc; touch files/etc/NIXOS";
            };
          in
            rootImage.overrideAttrs (old: {
              name = "librechat-guest-image";
              nativeBuildInputs = old.nativeBuildInputs ++ [pkgs.qemu-utils];
              buildCommand =
                old.buildCommand
                + ''
                  mv "$out" root.img
                  mkdir "$out"

                  qemu-img convert -c -f raw -O qcow2 root.img "$out/nixos.qcow2"
                  qemu-img resize "$out/nixos.qcow2" 16G
                '';
            });
        };

        boot = {
          loader.grub.enable = false;
          initrd.availableKernelModules = ["virtio_pci" "virtio_blk" "virtio_net"];
          kernelParams = ["panic=1"];
        };
        fileSystems."/" = {
          device = "/dev/vda";
          fsType = "ext4";
          autoResize = true;
        };
        networking = {
          hostName = "librechat-conversation";
          useDHCP = true;
          usePredictableInterfaceNames = false;
          enableIPv6 = false;
          firewall.allowedTCPPorts = [8080];
          nftables = {
            enable = true;
            tables.librechat-control = {
              family = "inet";
              content = ''
                chain output {
                  type filter hook output priority filter; policy accept;
                  fib daddr type local meta skuid != 0 tcp dport { 2000, 8080, 8081 } reject with tcp reset
                }
              '';
            };
          };
        };
        services.openssh.enable = false;

        users = {
          groups.workspace.gid = workspaceGid;
          users.workspace = {
            uid = workspaceUid;
            group = "workspace";
            isSystemUser = true;
            home = "/mnt/data";
          };
        };

        environment.etc.gitconfig.text = ''
          [credential "https://github.com"]
            helper = !${pkgs.gh}/bin/gh auth git-credential
        '';
        systemd = {
          tmpfiles.rules = ["L+ /mnt/data - - - - /tmp/sandbox/session"];

          services = {
            register-nix-paths = {
              wantedBy = ["multi-user.target"];
              before = ["nix-daemon.socket" "librechat-guest.service"];
              after = ["local-fs.target"];
              unitConfig.ConditionPathExists = "/nix-path-registration";
              serviceConfig.Type = "oneshot";
              script = ''
                ${config.nix.package}/bin/nix-store --load-db < /nix-path-registration

                mkdir -p /nix/var/nix/profiles
                ln -sfn "$(readlink -f /run/current-system)" /nix/var/nix/profiles/system
                rm /nix-path-registration
              '';
            };

            librechat-guest = {
              wantedBy = ["multi-user.target"];
              after = ["network.target" "nftables.service"];
              requires = ["nftables.service"];
              unitConfig.FailureAction = "poweroff-force";
              serviceConfig = {
                ExecStart = "${lib.getExe pkgs.librechat-runtime} guest ${specification}";
                RuntimeDirectory = "librechat-guest";
                RuntimeDirectoryMode = "0755";
                Restart = "no";
                KillMode = "control-group";
                Delegate = true;
              };
            };
          };
        };
      })
    ];
  };
in {
  image = "${system.config.system.build.librechatImage}/nixos.qcow2";
  kernel = "${system.config.system.build.kernel}/${system.config.system.boot.loader.kernelFile}";
  initrd = "${system.config.system.build.initialRamdisk}/${system.config.system.boot.loader.initrdFile}";
  init = "${system.config.system.build.toplevel}/init";
  inherit system;
}
