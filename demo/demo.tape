# Records docs/demo.gif. Run from the repo root with OPENAI_API_KEY set: vhs demo/demo.tape
Output docs/demo.gif

Require nvim
Set Shell "bash"
Set FontFamily "Fira Code"
Set FontSize 18
Set Width 1100
Set Height 560
Set Padding 16
Set TypingSpeed 80ms

Hide
Type "nvim -u demo/init.lua demo/softmax.py" Enter
Sleep 2s
Show

Sleep 1s
Type "6G"
Sleep 400ms
Type "V"
Sleep 800ms
# <leader>we: explain the selected line
Type " we"
Sleep 5s
# <leader>ws: one level simpler, twice
Type " ws"
Sleep 5s
Type " ws"
Sleep 5s
Type "q"
Sleep 1.5s
