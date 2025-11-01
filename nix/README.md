# Dotfiles

My dotfiles. Uses Nix flakes to keep all my machines in sync - same packages,
same config, rollback if I break something.

## Structure

```text
nix/
├── flake.nix                 # Entry point
├── flake/parts/              # Flake-parts modules
├── lib/                      # Helper functions
├── os/                       # OS-specific config (darwin/linux)
├── profiles/                 # Composable profiles (base, desktop, cloud, etc.)
├── modules/                  # Program configs (git, zsh, neovim, etc.)
└── hosts/                    # Per-host configurations
```

Hosts live in `hosts/*.nix`, profiles in `profiles/*/default.nix`. The flake
finds them automatically.

Each host picks its profiles:

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

Or install Nix directly:

```bash
curl --proto '=https' --tlsv1.2 -sSf -L \
  https://install.determinate.systems/nix | sh -s -- install
```

### Deploy

Local:

```bash
nix run home-manager/master -- switch --flake .#HOSTNAME
```

After first run:

```bash
home-manager switch --flake .#HOSTNAME
```

Remote (with automatic rollback via deploy-rs):

```bash
deploy                    # all hosts
deploy .#HOSTNAME         # specific host
```

### Update

```bash
nix flake update
```

Then deploy as usual.

### Rollback

List generations:

```bash
home-manager generations
```

Activate an older one:

```bash
/nix/var/nix/profiles/per-user/$USER/home-manager-XX-link/activate
```

Or roll back via git:

```bash
git checkout <commit> flake.lock
home-manager switch --flake .#HOSTNAME
```

## Adding things

### Packages

Find packages at [search.nixos.org] and add to the appropriate profile:

- `base` - core tools everyone needs
- `desktop` - GUI apps
- `development` - dev tools
- `cloud` - cloud SDKs

### New host

Create `hosts/HOSTNAME.nix`:

```nix
{
  hostname = "hostname.example.com";
  os = "darwin";  # or "linux"
  arch = "aarch64";  # or "x86_64"
  profiles = [ "base" ];
}
```

The flake picks it up automatically.

### Configs

- Git identity: `modules/git/default.nix` or override in host files
- Shell: `modules/zsh/`
- Neovim: `modules/neovim/nvim/`
- New programs: create a module in `modules/` and import in a profile

## Troubleshooting

If a package isn't found, check [search.nixos.org] - some names differ in
nixpkgs (e.g. `yq` is `yq-go`).

If home-manager complains about existing dotfiles, back them up and remove them.

If deployment fails, check SSH works and Nix is installed on the remote.
`deploy --debug-logs` helps.

Running out of disk? `nix-collect-garbage -d`

[search.nixos.org]: https://search.nixos.org
