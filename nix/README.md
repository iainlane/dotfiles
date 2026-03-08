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

The flake is composed of _hosts_. Each host selects a set of _profiles_, and
those profiles can reference _modules_.

### Profiles

Profiles are composable bundles of behaviour and packages. They are used to
group related concerns (base tooling, desktop apps, cloud tooling, development
shells, and work-specific settings) so hosts can opt into them selectively.
Profile definitions are kept in `profiles/*/default.nix`.

- `base`: Core cross-platform CLI tooling and shell/editor configuration.
- `builder`: Cross-platform build helpers (Linux binfmt/QEMU and Darwin Linux
  builder VM opt-in).
- `cloud`: Cloud SDK and CLI packages (AWS, Azure, GCP).
- `containers`: Linux rootless container prerequisites (`newuidmap`/`newgidmap`
  wrappers and nodocker marker).
- `desktop`: GUI and desktop tooling, including terminals, editor integration,
  and fonts.
- `development`: Personal development project shells and language toolchains.
- `home`: Linux-focused personal project-directory shells (Debian/Ubuntu/GNOME
  workflows).
- `work`: Work-specific project shells, identity defaults, and tooling.

### Modules

We use _modules_ to break out configuration for specific programs or groups of
programs and keep it self-contained. They're imported into profiles.

- `ai`: AI tooling modules and shared MCP wiring.
- `cli-tools`: Common CLI programs and terminal utilities, including `direnv`
  integration.
- `ghostty`: Ghostty terminal configuration.
- `git`: Git defaults, aliases, signing, and ignore behaviour.
- `kitty`: Kitty terminal configuration and theme integration.
- `neovim`: Neovim runtime, settings, and plugin configuration.
- `nix`: Shared Nix settings, including binary cache/substituter configuration.
- `project-directories`: Generated `.envrc` management for configured project
  directories.
- `scripts`: Custom shell scripts installed into the environment.
- `starship`: Starship prompt configuration.
- `zed-editor`: Zed editor settings and extensions.
- `zsh`: Zsh shell configuration, plugins, and functions.

### Hosts

Hosts represent machines. A host record defines OS/architecture and the profiles
to apply, with optional per-host overrides. Host definitions are kept in
`hosts/*.nix`.

Profiles are selected per host:

```nix
{
  hostname = "hostname.example.com";
  os = "linux";
  arch = "x86_64";
  profiles = [ "base" "desktop" "development" "cloud" "work" ];

  # Optional per-host overrides
  homeModule = { ... }: {
    programs.git.settings.user.email = "work@example.com";
  };
}
```

## Usage

### Setup

```bash
./bootstrap.sh
```

Read the script. It's trivial.

### Running

We provide [`just`][just] targets. Run `./just --list` to see what is available,
then use the command below for normal maintenance:

tl;dr. Run:

```bash
./just update
```

This will refresh flake inputs (update to the latest packaged versions of
things), deploy the current system, and pre-build `direnv` shells (see
[above](#terms)).

To deploy to a managed remote system, run `./just update-host <hostname>`.

Or, the individual steps can be run separately.

[just]: https://just.systems/

#### `./just update-flake`

Update flake inputs to their latest versions. Give flake names as arguments,
e.g. `./just update-flake llm-agents` to only update those ones. That can be
useful to not update _everything_ at once.

#### `./just update-system`

Update both system and home configuration.

#### `./just update-home`

_Linux only - on MacOS, we use `nix-darwin` and its `darwin-rebuild` command
always updates both system and home together._

Update `home-manager` user-level configuration only.

####  `./just build-direnvs`

Pre-build `direnv` shells for all configured project directories. This just
means you don't have to wait when first `cd`ing into a project directory after a
flake update.

### Checks

Run `./just fmt` to check and fix formatting errors, `./just check` to run
broader static analysis, and `./just lint` to run them both.

### Debugging and exploration

To find packages, run `./just search <query>` and `./just info <package>`,

Try `./just why <package>` and `./just deps <package>` to trace why something is
installed. If a build fails, inspect logs with `./just log <package>`, and open
a REPL with `./just repl` for deeper investigation.

If an update goes wrong, inspect history with `./just generations`, review
recent generations with `./just history 5`, and compare two known generations
with `./just diff <gen1> <gen2>`.

### Cleanup

Track disk usage growth with `./just size` and `./just sizes`, prune older
version with `./just gc <days>` (defaults to 30).

### New host

Create `hosts/HOSTNAME.nix` to add a new host:

```nix
{
  hostname = "hostname.example.com";
  os = "darwin";  # or "linux"
  arch = "aarch64";  # or "x86_64"
  profiles = [ "base" ];
}
```

## Secrets

Secrets are managed with [sops-nix], which decrypts them at activation time
using an [age] key derived from an SSH private key.

### Generating the age key

On each host that needs to decrypt secrets, generate a dedicated SSH key for
sops:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/age-sops -C "sops-nix age key" -N ""
```

Then derive the age public key and add it to `.sops.yaml` in the
[dotfiles-secrets] repo so that secrets can be encrypted for this host:

```sh
nix shell nixpkgs#ssh-to-age -c ssh-to-age < ~/.ssh/age-sops.pub
```

The private key must never be committed or added to the Nix store.

[age]: https://github.com/FiloSottile/age
[dotfiles-secrets]: https://github.com/iainlane/dotfiles-secrets
[sops-nix]: https://github.com/Mic92/sops-nix
