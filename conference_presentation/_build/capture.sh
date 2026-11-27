#!/bin/bash
# usage: capture.sh <en|ka>   (needs the local dev server on :8788 seeded by seed.py)
L=$1; B=$(cd "$(dirname "$0")" && pwd); O=$B/../assets/screens/$L
export TOK=$B/tokens.json
export QR=$(python3 $B/arch.py $L $TOK)
cd $B/tools
node shot.mjs $L phone join:travel_$L ${O}_st_travel.png 412 915 2.5 7000 "xy,185,318;wait,2500" &
node shot.mjs $L phone join:coords_$L ${O}_st_coords.png 412 915 2.5 7000 &
node shot.mjs $L phone join:puzzle_$L ${O}_st_puzzle.png 412 915 2.5 9000 &
wait
node shot.mjs $L phone join:layout_$L ${O}_st_layout.png 412 915 2.5 7000 &
node shot.mjs $L phone join:plates_$L ${O}_st_plates.png 412 915 2.5 7000 "xy,206,621;wait,3000" &
node shot.mjs $L phone join:travel_$L ${O}_st_privacy.png 412 915 2.5 7000 "xy,351,27;wait,2000" &
wait
node shot.mjs $L desk "" ${O}_home.png 1440 900 1.5 6000 &
node shot.mjs $L desk "" ${O}_teacher_travel.png 1440 900 1.5 6000 "xy,826,390;wait,6000" &
node shot.mjs $L desk "" ${O}_new.png 1440 900 1.5 6000 "xy,1348,855;wait,2500" &
wait
node shot.mjs $L desk "" ${O}_qr.png 1440 900 1.5 6000 "xy,826,390;wait,5000;xy,1340,27;wait,2500"
