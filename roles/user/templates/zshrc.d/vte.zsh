if ! [ -v VTE_VERSION ] && ! [ -v TILIX_VERSION ]; then
  return
fi

source /etc/profile.d/vte-2.91.sh
