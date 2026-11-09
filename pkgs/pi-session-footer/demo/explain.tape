Output demo/explain.gif

Require node
Require git

Set Shell "bash"
Set Columns 60
Set Rows 8
Set FontFamily "CaskaydiaMono Nerd Font Mono"
Set FontSize 16
Set Padding 12
Set Framerate 8
Set CursorBlink false
Set TypingSpeed 30ms

Hide
Type "export PS1='$ '; clear"
Enter
Type "node demo/run.ts"
Enter
Wait+Screen@30s /footer-demo/
Sleep 500ms
Type "Show the scripted summary."
Enter
Wait+Screen@20s /No public service was contacted\./
Wait+Screen@10s /25\.0%/
Type "/footer explain"
Sleep 500ms
Enter 2
Wait+Screen@10s /Footer › Explain/
Show
Sleep 2s
Down@200ms 10
Up@300ms 3
Sleep 1s
Screenshot demo/legend.png
Sleep 1s
Down@300ms 2
Sleep 1s
Up@300ms 2
Enter
Wait+Screen@10s /Cache hit rate/
Sleep 1s
Screenshot demo/explain.png
Sleep 2s
Escape
Sleep 1s
Escape
Sleep 500ms
Hide
Ctrl+d
Sleep 500ms
