Require node
Require git

Set Shell "bash"
Set Columns 60
Set Rows 18
Set FontFamily "CaskaydiaMono Nerd Font Mono"
Set FontSize 16
Set Padding 12
Set CursorBlink false
Set TypingSpeed 20ms

Hide
Type "export PS1='$ '; clear"
Enter
Type "node demo/run.ts"
Enter
Wait+Screen@30s /footer-demo/
Type "Show the scripted summary."
Enter
Wait+Screen@20s /No public service was contacted\./
Wait+Screen@10s /25\.0%/
Sleep 1s
Show
Screenshot demo/narrow.png
Sleep 500ms
Hide
Ctrl+d
