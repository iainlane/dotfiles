GPG_TTY=$(tty)
export GPG_TTY

HOSTNAME=$(hostname)

if [ -e "~/.keychain/${HOSTNAME}-sh" ]; then 
  source ~/.keychain/${HOSTNAME}-sh
fi

if [ -e "~/.keychain/${HOSTNAME}-sh-gpg" ]; then
  source ~/.keychain/${HOSTNAME}-sh-gpg
fi

if [ -z "${GPG_AGENT_INFO}" ] || [ -z "${SSH_AUTH_SOCK}" ] && [ -x /usr/bin/keychain ]; then
    eval $(keychain --eval --quick --quiet --agents gpg,ssh --host ${HOSTNAME})
fi

# define profiles based on directories:
zstyle ":chpwd:profiles:${HOME}/dev/debian(|/|/*)"       profile debian
zstyle ":chpwd:profiles:${HOME}/dev/ubuntu(|/|/*)"       profile ubuntu
zstyle ":chpwd:profiles:${HOME}/dev/canonical(|/|/*)"    profile canonical
zstyle ":chpwd:profiles:${HOME}/dev/gnome(|/|/*)"        profile gnome
zstyle ":chpwd:profiles:${HOME}/dev/grafana(|/|/*)"      profile grafana

export NAME="Iain Lane"

chpwd_profile_debian()
{
  if [[ "${profile}" == "${CHPWD_PROFILE}" ]]; then
    return 1
  fi

  export EMAIL="laney@debian.org"
  export DEB_VENDOR=Debian
  export ZSH_USERNAME_COLOUR=red
  setup_environment
}

chpwd_profile_ubuntu()
{
  if [[ "${profile}" == "${CHPWD_PROFILE}" ]]; then
    return 1
  fi

  export EMAIL="laney@ubuntu.com"
  export DEB_VENDOR=Ubuntu
  export ZSH_USERNAME_COLOUR=yellow

  setup_environment
}

chpwd_profile_canonical()
{
  if [[ "${profile}" == "${CHPWD_PROFILE}" ]]; then
    return 1
  fi

  export EMAIL="iain.lane@canonical.com"
  export DEB_VENDOR=Ubuntu
  export ZSH_USERNAME_COLOUR=magenta

  setup_environment
}

chpwd_profile_gnome()
{
  if [[ "${profile}" == "${CHPWD_PROFILE}" ]]; then
    return 1
  fi

  export EMAIL="iainl@gnome.org"
  export DEB_VENDOR=Ubuntu
  export ZSH_USERNAME_COLOUR=green

  setup_environment
}

chpwd_profile_grafana()
{
  if [[ "${profile}" == "${CHPWD_PROFILE}" ]]; then
    return 1
  fi

  export EMAIL="iain@grafana.com"
  export ZSH_USERNAME_COLOUR=cyan
  export GPGKEY=0xAB2F5FB2C0B9FCE22B9D773B3B590AA273354714

  setup_environment
}

chpwd_profile_default()
{
  if [[ "${profile}" == "${CHPWD_PROFILE}" ]]; then
    return 1
  fi

  export GPGKEY="0xE352D5C51C5041D4"
  export EMAIL="iain@orangesquash.org.uk"
  unset DEB_VENDOR
  export ZSH_USERNAME_COLOUR=blue

  setup_environment
}

chpwd_profiles
