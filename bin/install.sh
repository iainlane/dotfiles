#!/bin/sh

# Symiink the dotfiles. This is used by dev containers. On the base system,
# Ansible is used instead.

SCRIPTDIR=$(cd "$(dirname "$0")" && pwd -P)

# Install the dotfiles.
ln -s "${SCRIPTDIR}/roles/user/templates/zshrc" "${HOME}/.zshrc"
ln -s "${SCRIPTDIR}/roles/user/templates/zshrc.local" "${HOME}/.zshrc"
