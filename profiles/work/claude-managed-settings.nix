{
  lib,
  pkgs,
  ...
}: let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;

  # Block reading, editing and writing each of the given path globs.
  noAccess = lib.concatMap (path: [
    "Read(${path})"
    "Edit(${path})"
    "Write(${path})"
  ]);

  # Secret-bearing paths denied on every platform.
  secretFiles = [
    "//**/.env"
    "//**/.env.*"
    "//**/*.pem"
    "//**/*.key"
    "//**/*.p12"
    "//**/*.pfx"
    "//**/id_rsa"
    "//**/id_ed25519"
    "//**/id_ecdsa"
    "//**/.ssh/**"
    "//**/.aws/credentials"
    "//**/.aws/config"
    "//**/.netrc"
    "//**/.gnupg/**"
    "//**/secrets/**"
    "//**/vault/**"

    "//**/.config/gcloud/**"
    "//**/application_default_credentials.json"
    "//**/*-serviceaccount.json"
    "//**/*-service-account.json"
    "//**/*_serviceaccount.json"
    "//**/*-credentials.json"
    "//**/gcloud/legacy_credentials/**"
    "//**/gcloud/access_tokens.db"
    "//**/gcloud/credentials.db"

    "//**/.kube/config"
    "//**/.kube/config.*"
    "//**/.kube/cache/**"
    "//**/.kube/http-cache/**"
    "//**/run/secrets/kubernetes.io/**"
    "//**/var/run/secrets/kubernetes.io/**"

    "//**/terraform.tfstate"
    "//**/terraform.tfstate.backup"
    "//**/terraform.tfvars"
  ];

  # Network and privilege-escalation commands we never want run unattended.
  dangerousCommands = [
    "Bash(nc:*)"
    "Bash(netcat:*)"
    "Bash(ncat:*)"
    "Bash(socat:*)"
    "Bash(ssh:*)"
    "Bash(scp:*)"
    "Bash(sftp:*)"
    "Bash(autossh:*)"
    "Bash(httpie:*)"
    "Bash(http:*)"
    "Bash(https:*)"
    "Bash(dig:*)"
    "Bash(nslookup:*)"
    "Bash(host:*)"
    "Bash(nmap:*)"
    "Bash(tcpdump:*)"
    "Bash(tshark:*)"
    "Bash(wireshark:*)"
    "Bash(ftp:*)"
    "Bash(lftp:*)"

    "Bash(sudo:*)"
    "Bash(su:*)"
    "Bash(doas:*)"
    "Bash(pkexec:*)"
  ];

  # Further credential stores denied on every platform.
  credentialStores = [
    "//**/.config/gh/hosts.yml"
    "//**/.boto/**"
    "//**/.azure/**"
  ];

  # Linux credential stores: keyrings, browser profiles and system files.
  linuxSecrets = [
    "//**/.local/share/keyrings/**"
    "//**/.config/google-chrome/**"
    "//**/.mozilla/firefox/**"
    "//**/.config/chromium/**"

    "//etc/ssl/private/**"
    "//etc/shadow"
    "//etc/sudoers"
    "//etc/sudoers.d/**"
  ];

  # macOS credential stores: the Keychain and browser profiles.
  macosSecrets = [
    "//**/Library/Keychains/**"
    "//**/Library/Application Support/Google/Chrome/**"
    "//**/Library/Application Support/Firefox/**"
  ];

  platformSecrets =
    if isDarwin
    then macosSecrets
    else linuxSecrets;
in {
  dotfiles.claudeCode.managedSettings = {
    "$schema" = "https://json.schemastore.org/claude-code-settings.json";

    allowManagedPermissionRulesOnly = true;

    cleanupPeriodDays = 90;

    permissions = {
      defaultMode = "auto";
      disableBypassPermissionsMode = "disable";

      deny =
        noAccess secretFiles
        ++ dangerousCommands
        ++ noAccess credentialStores
        ++ noAccess platformSecrets;

      ask = [
        "Bash(git push:*)"
        "Bash(git clean:*)"

        "Bash(npm install:*)"
        "Bash(pip install:*)"
        "Bash(brew install:*)"
        "Bash(cargo add:*)"
        "Bash(go get:*)"

        "Bash(docker compose:*)"

        "Bash(kubectl apply:*)"
        "Bash(kubectl delete:*)"
        "Bash(kubectl exec:*)"

        "Bash(terraform apply:*)"
        "Bash(terraform destroy:*)"

        "Bash(helm install:*)"
        "Bash(helm upgrade:*)"

        "Bash(gcloud projects delete:*)"
        "Bash(gcloud projects create:*)"
        "Bash(aws iam:*)"
        "Bash(aws s3 rm:*)"
        "Bash(az group delete:*)"

        "Bash(gh secret:*)"
        "Bash(gh variable:*)"

        "Bash(chainctl iam organizations delete:*)"
        "Bash(apko publish:*)"
      ];

      allow = [
        "Bash(git log:*)"
        "Bash(git diff:*)"
        "Bash(git status:*)"
        "Bash(git show:*)"
        "Bash(git branch:*)"
        "Bash(git fetch:*)"

        "Bash(ls:*)"
        "Bash(cat:*)"
        "Bash(grep:*)"
        "Bash(find:*)"
        "Bash(pwd:*)"
        "Bash(echo:*)"
        "Bash(which:*)"
        "Bash(wc:*)"

        "Bash(npm run:*)"
        "Bash(npm ci:*)"
        "Bash(npm test:*)"
        "Bash(npx:*)"
        "Bash(yarn:*)"
        "Bash(pnpm run:*)"
        "Bash(make:*)"
        "Bash(cargo build:*)"
        "Bash(cargo test:*)"
        "Bash(go build:*)"
        "Bash(go test:*)"
        "Bash(pytest:*)"
        "Bash(python:*)"
        "Bash(node:*)"

        "Bash(eslint:*)"
        "Bash(prettier:*)"
        "Bash(ruff:*)"
        "Bash(black:*)"
        "Bash(tsc:*)"
      ];
    };
  };
}
