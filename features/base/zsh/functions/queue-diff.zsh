local RELEASE DIFF DIR

RELEASE="$(ubuntu-distro-info --devel)"

if ! DIFF="$(queuediff -s "${RELEASE}" "${1}" 2>/dev/null)"; then
  DIR="$(mktemp -d)"

  pushd "${DIR}" >/dev/null || {
    rm -rf "${DIR}"
    return 1
  }

  # zsh pops the local scope before running an exit trap, so expand the
  # directory into the trap now.
  trap "popd >/dev/null; rm -rf ${(q)DIR}" EXIT INT QUIT HUP

  pull-lp-source "${1}" "${RELEASE}" -d >/dev/null || return 1
  queue -Q unapproved -s "${RELEASE}-proposed" --source fetch "${1}" >/dev/null || return 1

  DIFF="$(debdiff --auto-ver-sort ./*.dsc)"
fi

echo "${DIFF}"
