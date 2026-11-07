#!/usr/bin/env bash

set -euo pipefail

hermes_home="${1}"
owner="${2}"

touch "${hermes_home}/config.yaml"
chmod 0600 "${hermes_home}/config.yaml"
chown "${owner}" "${hermes_home}/config.yaml"
rm -f "${hermes_home}/.managed"
