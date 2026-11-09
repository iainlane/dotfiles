Require node
Require git

Set Shell "bash"
Set Columns 100
Set Rows 16
Set FontFamily "CaskaydiaMono Nerd Font Mono"
Set FontSize 16
Set Padding 12
Set Theme "Github"
Set CursorBlink false
Set TypingSpeed 20ms

Hide
Type "export PS1='$ '; clear"
Enter
Type "node demo/run.ts --preset minimal --theme light"
Enter
Wait+Screen@30s /footer-demo/
Type "Show the scripted summary."
Enter
Wait+Screen@20s /No public service was contacted\./
Sleep 1s
Show
Screenshot demo/minimal.png
Sleep 500ms
Hide
Ctrl+d
