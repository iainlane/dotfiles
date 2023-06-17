#!/bin/sh

# Symiink the dotfiles. This is used by dev containers. On the base system,
# Ansible is used instead.

SCRIPTDIR=$(cd "$(dirname "$0")" && pwd -P)
ROOT="$(realpath "${SCRIPTDIR}/..")"

# Install the dotfiles.
ln -s "${ROOT}/roles/user/templates/zshrc" "${HOME}/.zshrc"
ln -s "${ROOT}/roles/user/templates/zshrc.local" "${HOME}/.zshrc"
