local DIST

if [ $# -lt 1 ]; then
    echo "ERROR: who-can-upload: Must give a package" > /dev/stderr
    return 1
fi

if (( ! $+commands[edit-acl] )); then
    echo "ERROR: edit-acl is not in \$PATH. Clone https://git.launchpad.net/ubuntu-archive-tools and add the directory containing edit-acl to \$PATH." > /dev/stderr
    return 1
fi

DIST="$(ubuntu-distro-info -d)"

while (( $# > 0 )); do
    edit-acl -s "${1}" -S "${DIST}" query
    shift
done
