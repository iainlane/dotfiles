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
fi
