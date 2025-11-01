#!/bin/sh

set -e

echo "trusted-users = root @sudo @admin" | sudo tee -a /etc/nix/nix.custom.conf

sudo systemctl restart nix-daemon

curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
