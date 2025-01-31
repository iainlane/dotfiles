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
 local style
 zstyle -s ':laney:editor:emacs:cursor' style style || style=2
 printf '\e[%s q' $style
}

zle -N zle-line-init update-cursor-style
