Output demo/recording.gif

Require pi
Require node
Require vim

Set Shell "bash"
Set Columns 96
Set Rows 40
Set FontFamily "Menlo"
Set FontSize 16
Set Padding 16
Set Framerate 10
Set CursorBlink false
Set TypingSpeed 40ms

Env TMPDIR "/tmp"

Hide
Type "export PS1='$ '; clear"
Enter
Type "bash demo/run.bash"
Enter
Wait+Screen@30s /scripted/
Show

Type "Plan a --dry-run flag for the cleanup CLI."
Enter
Wait+Screen@30s /Enter Plan mode\?/
Sleep 2s
Enter
Wait+Screen@30s /Ready to code\?/
Sleep 2s

PageUp
Sleep 2s
PageDown
Sleep 2s

Ctrl+g
Wait+Screen@20s /PLAN-EDITOR/
Sleep 1s
Type "Go"
Type "- Verify dry-run never removes a file."
Escape
Sleep 2s
Type ":wq"
Enter

Wait+Screen@20s /Ready to code\?/
Sleep 2s
Tab
Type "Preserve the existing command-line interface."
Sleep 2s
Tab
Up
Sleep 1s
Enter
Wait+Screen@30s /Offline demo complete\./
Wait+Screen@5s /(?s)\?\/128k\s+scripted\s*$/
Sleep 4s

Hide
Ctrl+c
Ctrl+d
