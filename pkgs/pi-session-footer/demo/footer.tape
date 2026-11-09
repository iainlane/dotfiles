Output demo/footer.gif

Require node
Require git

Set Shell "bash"
Set Columns 110
Set Rows 22
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
Show
Screenshot demo/idle.png
Sleep 2s

Type "Show the scripted summary."
Enter
Wait+Screen@20s /No public service was contacted\./
Wait+Screen@10s /25\.0%/
Sleep 1s
Screenshot demo/usage.png
Sleep 2s

Type "/footer config"
Sleep 500ms
Enter 2
Wait+Screen@10s /Footer › Customise/
Enter
Wait+Screen@10s /Customise › Profile/
Down@200ms 2
Sleep 1s
Screenshot demo/config.png
Sleep 2s
Enter
Escape
Wait+Screen@10s /25\.0%/
Sleep 1s

Type "/footer config"
Sleep 500ms
Enter 2
Wait+Screen@10s /Footer › Customise/
Down
Enter
Wait+Screen@10s /Customise › Widgets/
Enter
Wait+Screen@10s /Widgets › Top left/
Down@200ms 4
Enter
Wait+Screen@10s /Git · Top left/
Down@200ms 2
Enter
Wait+Screen@10s /Text colour/
Enter
Wait+Screen@10s /Top left › Symbol/
Type "Custom text"
Sleep 500ms
Enter
Wait+Screen@10s /Custom symbol/
Type "[G]"
Sleep 1s
Enter
Wait+Screen@10s /Text colour/
Down
Enter
Wait+Screen@10s /Symbol colour/
Down
Sleep 1s
Enter
Down
Enter
Wait+Screen@10s /Text colour/
Down@200ms 2
Sleep 1s
Enter
Sleep 1s
Screenshot demo/appearance.png
Sleep 2s
Escape@200ms 4
Wait+Screen@10s /Source & saving/
Down
Enter
Wait+Screen@10s /Before right-hand group/
Enter
Down@200ms 4
Enter
Wait+Screen@10s /Custom separator/
Type " | "
Sleep 1s
Screenshot demo/separators.png
Sleep 2s
Enter
Escape
Wait+Screen@10s /Source & saving/
Down
Enter
Wait+Screen@10s /Extension symbols/
Sleep 1s
Escape
Down@200ms 2
Enter
Wait+Screen@10s /Footer saved\./
Sleep 2s

Hide
Ctrl+d
Sleep 500ms
