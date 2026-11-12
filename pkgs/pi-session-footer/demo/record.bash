#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
export TMPDIR="${TMPDIR:-/tmp}"
vhs validate 'demo/*.tape'
vhs demo/footer.tape
vhs demo/explain.tape
vhs demo/narrow.tape
vhs demo/minimal.tape
for scenario in footer explain; do
	ffmpeg -hide_banner -loglevel error -y -i "demo/$scenario.gif" \
		-c:v libwebp_anim -quality 65 -compression_level 6 -loop 0 "demo/$scenario.webp"
	rm -- "demo/$scenario.gif"
done
for scenario in idle usage narrow minimal; do
	ffmpeg -hide_banner -loglevel error -y -i "demo/$scenario.png" \
		-vf 'crop=iw:120:0:ih-120' -frames:v 1 "demo/$scenario.crop.png"
	mv -- "demo/$scenario.crop.png" "demo/$scenario.png"
done
