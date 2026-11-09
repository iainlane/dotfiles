# REA

Add `features.ai.rea` to a host's feature list for [REA], a reverse-engineering
CLI and MCP server. The feature installs `rea`, registers its MCP server with
the shared harnesses and adds the `reverse-engineer-anything` skill.

Nix manages registration; do not run `rea setup` to configure these harnesses.
The server and skill belong to the `rea` bundle. Harnesses with bundle
exclusions can omit both together.

[REA]: https://github.com/morluto/rea

## Tools and platform support

The configured command provides:

| Platform            | Tools                                               |
| ------------------- | --------------------------------------------------- |
| All supported hosts | Ghidra, Kuna, Wireshark tools and headless Chromium |
| Linux               | GDB, Binwalk, Unblob and mitmproxy                  |
| Linux x64           | pwntools with its Python dependencies, and Wakaru   |

Ghidra and Kuna are also installed as standalone commands. REA's platform
restrictions still apply. Hopper, IDA and Frida are not included.

Tools come from unstable even on stable hosts. Update the local REA and Wakaru
packages from the repository root with `./just update-pkg rea` and
`./just update-pkg wakaru`. Package-specific compatibility constraints are
defined under `pkgs/rea/` at the repository root.
