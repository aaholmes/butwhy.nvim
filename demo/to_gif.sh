#!/usr/bin/env bash
# Turns a screen recording into docs/latex.gif, optionally trimmed:
#   demo/to_gif.sh recording.mov [start seconds] [duration seconds] [output]
# Set CROP=width:height:x:y (in the recording's pixels) to cut away the window's title bar and edges.
set -euo pipefail
in=$1 start=${2:-0} duration=${3:-} out=${4:-docs/latex.gif}
trim=(-ss "$start")
[ -n "$duration" ] && trim+=(-t "$duration")
filters="${CROP:+crop=$CROP,}fps=12,scale=1100:-1:flags=lanczos"
palette=$(mktemp -t butwhy-palette).png
ffmpeg -y -loglevel error "${trim[@]}" -i "$in" -vf "$filters,palettegen=stats_mode=diff" "$palette"
ffmpeg -y -loglevel error "${trim[@]}" -i "$in" -i "$palette" -lavfi "$filters [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=5" "$out"
ls -lh "$out"
