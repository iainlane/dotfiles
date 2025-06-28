# Common aliases
alias chmod="chmod -v"
alias chown="chown -v"
alias cp="cp -iv"
alias ln="ln -v"
alias mkdir="mkdir -v"
alias mv="mv -iv"
alias rm="rm -v"
alias vim=nvim

if (( $+commands[bat] )); then
  alias cat=bat

  # Colourise manpages with `bat`
  # From https://github.com/sharkdp/bat?tab=readme-ov-file#man
  export MANPAGER="sh -c 'sed -u -e \"s/\\x1B\[[0-9;]*m//g; s/.\\x08//g\" | bat -p -lman'"
fi
