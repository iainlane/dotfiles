# Set :laney:editor:emacs:cursor to one of the following values:
#
# Set cursor style (DECSCUSR), VT520.
# 0  ⇒  blinking block.
# 1  ⇒  blinking block (default).
# 2  ⇒  steady block.
# 3  ⇒  blinking underline.
# 4  ⇒  steady underline.
# 5  ⇒  blinking bar, xterm.
# 6  ⇒  steady bar, xterm.

function update-cursor-style {
  # Only apply cursor styling to xterm, rxvt, or tmux terminal families
  if [[ "${TERM}" != xterm(|-*) && "${TERM}" != rxvt(|-*) && "${TERM}" != tmux(|-*) && -z "${TMUX}" ]]; then
    return
  fi

  local style
  if ! zstyle -s ':laney:editor:emacs:cursor' style style; then
    # Our default style is a steady block.
    style=2
  fi

  printf '\e[%s q' ${style}
}

zle -N zle-line-init update-cursor-style
zle -N zle-keymap-select update-cursor-style

# Reset the cursor to the default style when the shell exits.
function cleanup-cursor {
  printf '\e[0 q'
}
autoload -Uz add-zsh-hook

add-zsh-hook zshexit cleanup-cursor
