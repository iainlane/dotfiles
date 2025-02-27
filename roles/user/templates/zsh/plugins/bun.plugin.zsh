# bun completions
if (( $+commands[bun] )); then
  [ -s ~/.bun/_bun ] || bun completions
  fpath=(~/.bun/ ${fpath})
fi

