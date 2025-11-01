# zstyles that need to be loaded after plugins

# NOTE: don't use escape sequences (like '%F{red}%d%f') here, fzf-tab will ignore them

# set descriptions format to enable group support
zstyle ':completion:*' format '[%d]'
zstyle ':completion:*:descriptions' format '[%d]'
zstyle ':completion:*:messages' format '[%d]'
zstyle ':completion:*:warnings' format '[%d]'
zstyle ':completion:*:corrections' format '[%d (errors: %e)]'

# set list-colors to enable filename colorizing
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
# force zsh not to show completion menu, which allows fzf-tab to capture the unambiguous prefix
zstyle ':completion:*' menu no

# fzf-tab options
## Show full group names
zstyle ':fzf-tab:*' show-group full
## Trigger continuous completion with /
zstyle ':fzf-tab:*' continuous-trigger '/'
## Switch group using `<` and `>`
zstyle ':fzf-tab:*' switch-group '<' '>'
## Explicitly set fzf flags that work well with completions
## Note: using ~80% (with ~) for proper height handling in completion mode
zstyle ':fzf-tab:*' fzf-flags --height=~80% --min-height=15 --layout=reverse --border=rounded --cycle --multi

# preview file contents with bat or directory contents with eza
zstyle ':fzf-tab:complete:*:*' fzf-preview '
  if [[ -f "${realpath}" ]]; then
    bat --color=always --style=numbers --line-range=:200 "${realpath}"
  elif [[ -d "${realpath}" ]]; then
    eza --tree --level 2 --color always --icons always "${realpath}"
  fi'

# git previews
zstyle ':fzf-tab:complete:git-(add|diff|restore):*' fzf-preview '
  git diff "${word}" 2>/dev/null | delta || echo "Not in a git repository or invalid ref"'
zstyle ':fzf-tab:complete:git-log:*' fzf-preview '
  git log --color=always "${word}" 2>/dev/null || echo "Not in a git repository or invalid ref"'
zstyle ':fzf-tab:complete:git-help:*' fzf-preview '
  git help "${word}" 2>/dev/null | bat -plman --color=always || echo "No help available for ${word}"'
zstyle ':fzf-tab:complete:git-show:*' fzf-preview '
  case "${group}" in
    "commit tag") git show --color=always "${word}" 2>/dev/null ;;
    *) git show --color=always "${word}" 2>/dev/null | delta ;;
  esac || echo "Not in a git repository or invalid ref"'
zstyle ':fzf-tab:complete:git-checkout:*' fzf-preview '
  case "${group}" in
    "modified file") git diff "${word}" 2>/dev/null | delta ;;
    "recent commit object name") git show --color=always "${word}" 2>/dev/null | delta ;;
    *) git log --color=always "${word}" 2>/dev/null ;;
  esac || echo "Not in a git repository or invalid ref"'

# systemd previews
zstyle ':fzf-tab:complete:systemctl-*:*' fzf-preview '
  if command -v systemctl &>/dev/null; then
    systemctl status "${word}" 2>/dev/null
  fi'

# journalctl preview
zstyle ':fzf-tab:complete:journalctl:*' fzf-preview '
  if command -v journalctl &>/dev/null; then
    journalctl -u "${word}" -n 50 --no-pager 2>/dev/null
  fi'

# docker/podman previews
zstyle ':fzf-tab:complete:docker-(run|images):*' fzf-preview '
  case "${group}" in
    "image") docker images "${word}" 2>/dev/null ;;
    *) docker inspect "${word}" 2>/dev/null | bat -l json --color=always ;;
  esac'

zstyle ':fzf-tab:complete:docker-(start|stop|restart|rm):*' fzf-preview '
  docker inspect "${word}" 2>/dev/null | bat -l json --color=always'

# npm preview
zstyle ':fzf-tab:complete:npm-*:*' fzf-preview '
  if command -v npm &>/dev/null && [[ -f package.json ]]; then
    npm info "${word}" 2>/dev/null || cat package.json | bat -l json --color=always
  fi'

# cargo preview
zstyle ':fzf-tab:complete:cargo-*:*' fzf-preview '
  if ! command -v cargo &>/dev/null || ! [[ -f Cargo.toml ]]; then
    exit 0
  fi

  cargo search "${word}" --limit 1 2>/dev/null || cat Cargo.toml | bat -l toml --color=always'

# environment variables
for cmd in export unset; do
  zstyle ":fzf-tab:complete:${cmd}:*" fzf-preview 'printenv "${word}" 2>/dev/null'
done

# tldr preview
zstyle ':fzf-tab:complete:tldr:argument-1' fzf-preview 'tldr --color always "${word}"'

# command preview with fallback chain
zstyle ':fzf-tab:complete:-command-:*' fzf-preview '
  if out=$(tldr --color always "${word}" 2>/dev/null); then
    echo "${out}"
  elif out=$(MANWIDTH="${FZF_PREVIEW_COLUMNS}" man "${word}" 2>/dev/null | sh -c "sed -u -e \"s/\[[0-9;]*m//g; s/\r//g\" | bat -p -lman") && [[ -n "${out}" ]]; then
    echo "${out}"
  elif out=$(which "${word}"); then
    echo "${out}"
  else
    echo "${(P)word}"
  fi'
