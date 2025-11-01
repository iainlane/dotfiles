# Set up gpg and SSH agents with keychain, if it's installed

GPG_TTY=$(tty)
export GPG_TTY

if [ -e "~/.keychain/${HOST}-local-sh" ]; then
  source ~/.keychain/${HOST}-local-sh
fi

if [ -e "~/.keychain/${HOST}-local-sh-gpg" ]; then
  source ~/.keychain/${HOST}-local-sh-gpg
fi

if [ -z "${GPG_AGENT_INFO}" ] || [ -z "${SSH_AUTH_SOCK}" ] && (( $+commands[keychain] )); then
    eval $(keychain --eval --quick --quiet --ssh-spawn-gpg --host ${HOST})
fi
