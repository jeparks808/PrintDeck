#!/usr/bin/env bash
# Install (or remove) PrintDeck's touchscreen mirror on a Centauri Carbon running COSMOS.
#   tools/screen-mirror/install.sh <printer-ip>            install / update, start, and start on every boot
#   tools/screen-mirror/install.sh <printer-ip> --remove   stop it and remove it
# Needs SSH as root to the printer. Files go to /data (kept across COSMOS updates) and /etc (COSMOS's overlay).
set -euo pipefail
IP=${1:?usage: $0 <printer-ip> [--remove]}
HERE=$(cd "$(dirname "$0")" && pwd)
SSH="ssh -o ConnectTimeout=8 ${SSH_OPTS:-} root@$IP"
if [ "${2:-}" = --remove ]; then
	$SSH '/etc/init.d/printdeck-screen stop 2>/dev/null; rm -f /etc/init.d/printdeck-screen /etc/rc?.d/S91printdeck-screen; rm -rf /data/printdeck/printdeck-screen.py'
	echo "Removed."; exit 0
fi
$SSH 'mkdir -p /data/printdeck && cat > /data/printdeck/printdeck-screen.py' < "$HERE/printdeck-screen.py"
$SSH 'cat > /etc/init.d/printdeck-screen && chmod 755 /etc/init.d/printdeck-screen' < "$HERE/printdeck-screen.init"
$SSH 'for r in 2 3 4 5; do [ -d /etc/rc$r.d ] && ln -sf ../init.d/printdeck-screen /etc/rc$r.d/S91printdeck-screen; done; /etc/init.d/printdeck-screen restart'
sleep 2
curl -fsS "http://$IP:8091/info" && echo && echo "Running on http://$IP:8091 (PrintDeck: Camera page → Touchscreen)."
