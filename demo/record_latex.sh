#!/usr/bin/env bash
# Plays the LaTeX demo in a fresh kitty window, for recording docs/latex.gif. VHS cannot record it:
# its terminal does not draw kitty graphics, which snacks.nvim uses for the equations.
# Run from the repo root with OPENAI_API_KEY set, and record the window while it plays
# (macOS: Cmd+Shift+5, "Record Selected Portion"). demo/to_gif.sh turns the recording into a GIF.
set -euo pipefail
sock="unix:${TMPDIR:-/tmp}/butwhy-demo-$$.sock"
kitty --config NONE -o allow_remote_control=socket-only --listen-on "$sock" \
  -o font_family='Fira Code' -o font_size=18 -o remember_window_size=no \
  -o window_padding_width=12 \
  -o macos_quit_when_last_window_closed=yes \
  --directory "$PWD" nvim -u demo/latex_init.lua demo/gaussian.md &
k() { kitty @ --to "$sock" "$@"; }
type_slowly() { local s=$1 i; for ((i = 0; i < ${#s}; i++)); do k send-text -- "${s:i:1}"; sleep 0.08; done; }

sleep 3
k resize-os-window --width 98 --height 24 --unit cells # the size of docs/demo.gif; initial_window_* is ignored
sleep "${START_DELAY:-6}" # time to render the equations and start recording
type_slowly '3G'; sleep 0.4
k send-text V; sleep 0.8
type_slowly ' wa'; sleep 1.2     # <leader>wa: ask about the selection
type_slowly 'Derive this'; sleep 0.6
k send-key ctrl+s                # send the question
sleep "${ANSWER_WAIT:-15}"
k send-text -- $'\x1c\x0e'     # <C-\><C-n>: Normal mode, whichever mode the pop-up is in
sleep 1
type_slowly 'q'; sleep 1.5       # close the pop-up
k send-text -- $':qa!\r'
