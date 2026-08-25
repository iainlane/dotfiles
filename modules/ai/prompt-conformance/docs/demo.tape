# Regenerates docs/demo.webp. Run from modules/ai/prompt-conformance:
#
#   PC_BIN="$(nix build --no-link --print-out-paths ../../..#claude-prompt-conformance)/bin" \
#     vhs docs/demo.tape
#   gif2webp -min_size -mixed docs/demo.gif -o docs/demo.webp
#   rm docs/demo.gif
#
# vhs cannot write WebP, so the tape records a GIF and gif2webp converts it.

Output docs/demo.gif

Set Shell "bash"
Set FontSize 12
Set Width 880
Set Height 560
Set Padding 12
Set Framerate 12
Set PlaybackSpeed 1.5
Set TypingSpeed 40ms

Hide
Type `PATH="$PC_BIN:$PATH"; PS1='$ '; clear`
Enter
Sleep 1s
Show

Type "claude-prompt-conformance --demo"
Enter

# Both waits match the cursor line. Wait+Screen stalls on this catalogue in
# vhs 0.11.0, so do not switch these to Screen scope.
Wait@60s /Tests/

Type "3,8"
Enter

# PS1 is "$ ", so this matches the shell prompt after the run exits.
Wait@180s /\$/
Sleep 3s
