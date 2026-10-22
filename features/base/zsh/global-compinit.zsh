if [[ -z ${skip_global_compinit:-} ]]; then
  autoload -Uz compinit
  compinit
fi
