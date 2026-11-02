#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
vhs demo/demo.tape
ffmpeg -hide_banner -loglevel error -y -i demo/recording.gif \
	-vf "fps=8,scale=864:-2" -c:v libwebp_anim -quality 60 \
	-compression_level 6 -loop 0 demo/planning.webp
rm -- demo/recording.gif
