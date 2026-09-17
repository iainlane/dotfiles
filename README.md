# Dotfiles

My dotfiles.

These are managed using [Nix].

[Nix]: https://nixos.org

## Terms

- `system` is used for machine-level Nix configuration (OS services, system
  packages, platform settings).
- `home` is used for user-level [Home Manager] configuration (shell, editor,
  per-user tools).
- `direnv` is used for directory-specific development shells. For example, when
  `cd`-ing into `~/code/myproject`, a `direnv` shell can be loaded with a `go`
  toolchain that is otherwise not on the `PATH`.

[Home Manager]: https://nix-community.github.io/home-manager/

## Structure

The flake is composed of _hosts_ and _features_. A host lists the features it
has. A feature is the configuration for one concern across every module system
that builds a host (NixOS, nix-darwin, system-manager and Home Manager), plus
the other features it includes.

For a fuller walk through `host → features → OS adapter → outputs`, see
[docs/architecture.md](docs/architecture.md).

### Features

Every feature lives in one directory under `features/` and registers itself
under `flake.features.<name>`. The directories are discovered automatically, and
only a `<name>/default.nix` one level down is loaded.

A feature is top-level when a host composes it in its own right. Everything else
is a child of its parent feature, registered under that feature's `provides` and
named `<parent>.<child>`, such as `base.zsh` or `desktop.gnome`. A child applies
only when something lists it in `includes`, so a parent lists the children that
always apply and puts the rest under the OS scopes. Anything can list a single
child on its own: `hosts/bonington` takes
`features.work.provides.claude-managed-settings` without the rest of `work`.

The twenty-one top-level features:

- `base`: Core cross-platform CLI tooling and shell/editor configuration.
  Children: `zsh`, `neovim`, `gh`, `ssh`, `starship`, `cli-tools`, `catppuccin`,
  `motd`, `scripts`, `nix`, `sudo`, and per OS `openssh`, `restic`,
  `system-manager-shell`, `homebrew` and `macos-defaults`.
- `desktop`: GUI and desktop tooling. Children: the terminals, the editors,
  `chrome`, `fonts`, `gpg-agent`, and per OS `gnome`, `usbguard`, `plymouth`,
  `console`, `tailscale`, `wine` and the rest.
- `development`: Personal development project shells and language toolchains.
  Children: `debuginfod`, `orbstack`.
- `work`: Work-specific project shells, identity defaults, and tooling.
  Children: `falcon`, `kolide`, `claude-managed-settings`.
- `home`: Personal identity and, on non-NixOS Linux, the `debian` child with the
  Debian, Ubuntu and GNOME project directories.
- `ai`: The shared MCP servers, skills and instructions, with one child per
  harness (`claude-code`, `codex`, `pi`, `opencode`, ...), plus `claude-desktop`
  and `cloudflare-mcp`, which other features list.
- `git`: Git defaults, aliases, signing, and ignore behaviour.
- `cloud`: Cloud SDK and CLI packages (AWS, Azure, GCP).
- `containers`: Linux rootless container prerequisites (`newuidmap`/`newgidmap`
  wrappers and nodocker marker).
- `network`: The systemd-networkd links of a system-manager host, and the LAN
  address that other features bind published container ports to.
- `inference`: A local model server, with `ollama` and `open-webui` as children
  so a host can run one without the other.
- `nixbuild-builder`: nixbuild.net remote build configuration, including
  build-machine registration and cross-architecture build support.
- `nixbuild-substituter`: nixbuild.net SSH substituter configuration without
  registering the host as a remote-build client.
- `agentsview` and `agentsview-server`: the archive of agent sessions on a
  machine that runs agents, and the shared database behind it.
- `hermes`: the containerised Hermes agent and its messaging, archive, webhook,
  MCP, identity, and backup children. See the [Hermes operator notes].
- `adsb`, `caddy`, `dex`, `hermes`, `matrix`, `unifi`: the services on ancaster.

[Hermes operator notes]: docs/hermes.md

The Neovim configuration is `nvim/` at the repository root, which `base.neovim`
installs.

### Hosts

Hosts represent machines. A host record defines OS/architecture, the host's
features, and any configuration that applies to this host alone. Each file under
`hosts/` is a flake-parts module that sets `flake.hosts.<name>`:

```nix
{config, ...}: let
  inherit (config.flake) features;
in {
  flake.hosts.example = {
    hostname = "hostname.example.com";
    os = "generic-linux";
    arch = "x86_64";
    motd = "Welcome to example";
    features = [
      features.base
      features.desktop
      features.development
      features.cloud
      features.work
    ];

    # Configuration for this host alone
    homeModule = {
      programs.git.settings.user.email = "work@example.com";
    };
  };
}
```

## Usage

### Setup

```bash
./bootstrap.sh
```

It installs Determinate Nix, adds the `sudo` and `admin` groups to
`trusted-users`, and restarts the daemon.

### Running

We provide [`just`][just] targets. Run `./just --list` to see what is available.
For normal maintenance, run:

```bash
./just update
```

This refreshes the flake inputs, moving packages to their latest packaged
versions, deploys the current system, and pre-builds the `direnv` shells (see
[above](#terms)).

To deploy to a managed remote system, run `./just update-host <hostname>`. To
deploy only the system or home deploy-rs profile, run
`./just update-host-system <hostname>` or `./just update-host-home <hostname>`.

The individual steps can also be run separately.

[just]: https://just.systems/

#### `./just update-flake`

Update flake inputs to their latest versions. Name inputs as arguments to update
only those, for example `./just update-flake llm-agents`.

An input pinned to a release tag in its URL, such as `hermes-agent`, does not
move this way. `update-pkgs` moves those.

#### `./just update-pkgs`

Run every registered updater. A package updater refreshes that package's source
metadata and any dependency pins it needs. A tag-pinned flake input's updater
moves the release tag in `flake.nix` and relocks that input.
`./just update-pkg <name>` runs a single one, for example
`./just update-pkg chainctl` or `./just update-pkg hermes-agent`.

#### `./just update-system`

Update both system and home configuration.

#### `./just update-home`

_Linux only. macOS is built with `nix-darwin`, whose `darwin-rebuild` always
updates system and home together._

Update `home-manager` user-level configuration only.

#### `./just build-direnvs`

Pre-build `direnv` shells for all configured project directories. With them
built, the first `cd` into a project directory after a flake update does not
wait for its shell.

### Checks

Run `./just fmt` to check and fix formatting errors, `./just check` to run
broader static analysis, and `./just lint` to run them both.

A pre-commit hook also runs the Python checks for the [prompt conformance
suite][prompt-conformance], which measures how a change to this repository's
assembled agent prompt affects real repository work. The hook requests a build
only when the commit touches an input to the checks, such as the instructions
and output styles under `features/ai/`, the flake inputs, or the suite itself.
Unchanged build inputs reuse the cached result.

[prompt-conformance]: pkgs/claude-prompt-conformance/README.md

### Debugging and exploration

To find packages, run `./just search <query>` and `./just info <package>`.

Try `./just why <package>` and `./just deps <package>` to trace why something is
installed. If a build fails, inspect logs with `./just log <package>`, and open
a REPL with `./just repl` for deeper investigation.

If an update goes wrong, inspect history with `./just generations`, review
recent generations with `./just history 5`, and compare two known generations
with `./just diff <gen1> <gen2>`.

## NixOS

Some hosts in this repo are full [NixOS][nixos] hosts rather than `nix-darwin`
or `system-manager` machines. You can find them in `hosts/` by looking for host
records with `os = "nixos"`.

Like everything else in this repo, these systems are declarative, but a full OS
install has to be provisioned before it can be updated. The steps below cover
that.

[nixos]: https://nixos.org/

### Generating keys

A new NixOS host needs cryptographic keys before it can decrypt secrets. Run:

```bash
./just generate-host-keys <host>
```

This creates an SSH host key, derives an age key from it, generates a user age
key, and updates `.sops.yaml` in the secrets repo. You will be prompted to
create any host-specific secrets (e.g. borgmatic SSH keys) via `sops`. The
recipe commits and pushes the secrets repo when done.

### Netboot / PXE

If the target machine has no OS on disk yet, netboot a minimal NixOS installer
using [`pixiecore`][pixiecore]:

```bash
./just netboot <host>
```

PXE-boot the target on the same network segment and find its IP. If the machine
already has a live environment reachable over SSH, skip this step.

[pixiecore]: https://github.com/danderson/netboot/tree/main/pixiecore

### Installing

Once the target is reachable over SSH, install with
[`nixos-anywhere`][nixos-anywhere]. Pass the keys directory printed by
`generate-host-keys` to inject them into the installed system:

```bash
./just install <host> <ip-or-hostname> /path/to/keys-dir
```

The keys are cleaned up locally after a successful install. The SSH host key is
installed at `/etc/ssh/ssh_host_ed25519_key` and the user age key at
`~/.config/sops/age/keys.txt`. Without a keys directory the install proceeds but
the host won't be able to decrypt secrets until keys are provided manually.

[nixos-anywhere]: https://github.com/nix-community/nixos-anywhere

### Updating

After the initial install, push configuration changes with:

```bash
./just update-host <host>
```

### Cleanup

Track disk usage growth with `./just size` and `./just sizes`, and delete
generations older than `<days>` with `./just gc <days>` (defaults to 30).

### New host

Create `hosts/HOSTNAME.nix` to add a new host:

```nix
{config, ...}: {
  flake.hosts.HOSTNAME = {
    hostname = "hostname.example.com";
    os = "darwin";  # or "generic-linux" (system-manager) or "nixos"
    arch = "aarch64";  # or "x86_64"
    motd = "Welcome to HOSTNAME";
    features = [config.flake.features.base];
  };
}
```

A host with hardware or disk configuration of its own is a directory instead,
`hosts/HOSTNAME/`, whose `default.nix` imports the files beside it from its
`systemModule`. `hosts/bonington/` is the example to copy.

## Secrets

Secrets are managed with [sops-nix], which decrypts them at activation time
using an [age] key derived from an SSH private key.

### Generating the age key

Key generation is handled by `./just generate-host-keys <host>` as part of the
[installation process](#generating-keys). Both the SSH host key (system-level
decryption) and a dedicated user age key are generated and injected during
install. The user key is written in standard age format at
`~/.config/sops/age/keys.txt`.

### Other hosts

On Darwin and Linux (system-manager) hosts, the simplest option is to generate a
standard age identity for `sops`:

```sh
mkdir -p ~/.config/sops/age
chmod 700 ~/.config/sops ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

Then derive the age public key and add it to `.sops.yaml` in the
[dotfiles-secrets] repo so that secrets can be encrypted for this host:

```sh
nix shell nixpkgs#age -c age-keygen -y ~/.config/sops/age/keys.txt
```

If you already have an SSH private key you want to reuse, convert it into
`keys.txt` instead of generating a fresh age key:

```sh
mkdir -p ~/.config/sops/age
chmod 700 ~/.config/sops ~/.config/sops/age
nix shell nixpkgs#ssh-to-age -c sh -c 'ssh-to-age -private-key -i ~/.ssh/your_key >> ~/.config/sops/age/keys.txt'
chmod 600 ~/.config/sops/age/keys.txt
```

The private key material must never be committed or added to the Nix store.

[age]: https://github.com/FiloSottile/age
[dotfiles-secrets]: https://github.com/iainlane/dotfiles-secrets
[sops-nix]: https://github.com/Mic92/sops-nix
