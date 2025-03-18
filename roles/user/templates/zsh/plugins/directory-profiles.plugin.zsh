function setup_environment() {
  export DEBFULLNAME=$NAME                # These are used by Debian packaging...
  export DEBEMAIL=$EMAIL                  # ...programs.
  export DEBSIGN_KEYID=$GPGKEY            # Key ID for signing Debian packages.
  export BZR_EMAIL="$NAME <$EMAIL>"       # Override email for Bazaar.
  export BRZ_EMAIL="$NAME <$EMAIL>"       # Override email for Bazaar.
  export GIT_AUTHOR_NAME=$NAME            # Use our real name for Git.
  export GIT_AUTHOR_EMAIL=$EMAIL          # and our email address
  export GIT_COMMITTER_EMAIL=$EMAIL       # ...too.
}

CHPWD_PROFILE='default'
function chpwd_profiles() {
    # Say you want certain settings to be active in certain directories.
    # This is what you want.
    #
    # zstyle ':chpwd:profiles:/usr/src/grml(|/|/*)'   profile grml
    # zstyle ':chpwd:profiles:/usr/src/debian(|/|/*)' profile debian
    #
    # When that's done and you enter a directory that matches the pattern
    # in the third part of the context, a function called chpwd_profile_grml,
    # for example, is called (if it exists).
    #
    # If no pattern matches (read: no profile is detected) the profile is
    # set to 'default', which means chpwd_profile_default is attempted to
    # be called.
    #
    # A word about the context (the ':chpwd:profiles:*' stuff in the zstyle
    # command) which is used: The third part in the context is matched against
    # ${PWD}. That's why using a pattern such as /foo/bar(|/|/*) makes sense.
    # Because that way the profile is detected for all these values of ${PWD}:
    #   /foo/bar
    #   /foo/bar/
    #   /foo/bar/baz
    # So, if you want to make double damn sure a profile works in /foo/bar
    # and everywhere deeper in that tree, just use (|/|/*) and be happy.
    #
    # The name of the detected profile will be available in a variable called
    # 'profile' in your functions. You don't need to do anything, it'll just
    # be there.
    #
    # Then there is the parameter $CHPWD_PROFILE is set to the profile, that
    # was is currently active. That way you can avoid running code for a
    # profile that is already active, by running code such as the following
    # at the start of your function:
    #
    # function chpwd_profile_grml() {
    #     [[ ${profile} == ${CHPWD_PROFILE} ]] && return 1
    #   ...
    # }
    #
    # The initial value for $CHPWD_PROFILE is 'default'.
    local -x profile

    zstyle -s ":chpwd:profiles:${PWD}" profile profile || profile='default'
    if (( ${+functions[chpwd_profile_$profile]} )) ; then
        chpwd_profile_${profile}
    fi

    CHPWD_PROFILE="${profile}"
    return 0
}
chpwd_functions=( ${chpwd_functions} chpwd_profiles )

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
