#!/usr/bin/env bash
# Run the simulated printer and carry it to the iPad over USB (SSH reverse tunnels via the `ipad` alias),
# then point PrintDeck at it. For trying the app without using the real printer. Ctrl-C stops everything.
#   sim/run-sim.sh [printing|finish|runout|idle] [speed, default 30]
# Afterwards, switch the app back to the real printer with:  ••• menu > Find printer on Wi-Fi
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCEN="${1:-printing}"; SPEED="${2:-30}"; BASE=13030; IPAD="${IPAD:-ipad}"   # IPAD=ipad-wifi when USB is busy
python3 -I "$HERE/printdeck_sim.py" --base "$BASE" --scenario "$SCEN" --speed "$SPEED" ${SIM_ARGS:-} &
SIM=$!
ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes \
	-R "127.0.0.1:$BASE:127.0.0.1:$BASE" -R "127.0.0.1:$((BASE + 1)):127.0.0.1:$((BASE + 1))" -R "127.0.0.1:$((BASE + 2)):127.0.0.1:$((BASE + 2))" "$IPAD" &
TUN=$!
trap 'kill $SIM $TUN 2>/dev/null' EXIT INT TERM
sleep 3
ssh "$IPAD" "su mobile -c 'uiopen \"printdeck://connect?host=127.0.0.1&port=$BASE&video=$((BASE + 1))\"'"
echo "Simulated printer ($SCEN) is on the iPad. Ctrl-C to stop."
wait $SIM
