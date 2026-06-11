#!/bin/sh

set -e

curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install

echo "trusted-users = root @sudo @admin" | sudo tee -a /etc/nix/nix.custom.conf

if command -v systemctl >/dev/null 2>&1; then
	sudo systemctl restart nix-daemon
else
	sudo launchctl kickstart -k system/org.nixos.nix-daemon
fi
