#!/usr/bin/env bash
# Install meshbridge on an OpenCentauri (patched firmware) Centauri Carbon so it runs now and at every boot.
#
#   tools/install-meshbridge.sh [printer-ip]          (default 192.168.0.185)
#   tools/install-meshbridge.sh [printer-ip] --remove
#
# Where it goes: OpenCentauri's boot script (/etc/init.d/oc-bootstrap) bind-mounts Kipware (Entware) from the
# persistent /user-resource partition onto /kip and runs `/kip/etc/init.d/rc.unslung start`, which starts every
# /kip/etc/init.d/S??* script. So this copies meshbridge.py to /kip/share/meshbridge/ and adds
# /kip/etc/init.d/S90meshbridge, which keeps it running (restarts it if it exits). Both live on
# /user-resource, so they survive reboots and firmware updates. Nothing in the firmware itself is changed.
#
# SSH asks for the root password once; later steps reuse that connection.
set -euo pipefail

IP=192.168.0.185
REMOVE=0
for a in "$@"; do
	case "$a" in
		--remove) REMOVE=1 ;;
		*) IP="$a" ;;
	esac
done
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HERE/meshbridge/meshbridge.py"
SOCK="$(mktemp -u /tmp/meshbridge-ssh.XXXXXX)"
SSH=(ssh -o ControlMaster=auto -o ControlPath="$SOCK" -o ControlPersist=120
     -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8)
# MESHBRIDGE_SSH_LOG=<file>: append SSH's debug output there (for "Connection closed" and similar).
[ -n "${MESHBRIDGE_SSH_LOG:-}" ] && SSH+=(-vv -E "$MESHBRIDGE_SSH_LOG")
SSH+=("root@$IP")
cleanup() { ssh -o ControlPath="$SOCK" -O exit "root@$IP" 2>/dev/null || true; rm -f "$SOCK"; }
trap cleanup EXIT

echo "== Connecting to $IP"
"${SSH[@]}" true

if [ "$REMOVE" = 1 ]; then
	"${SSH[@]}" 'sh -s' <<'EOF'
[ -x /kip/etc/init.d/S90meshbridge ] && /kip/etc/init.d/S90meshbridge stop
rm -f /kip/etc/init.d/S90meshbridge
rm -rf /kip/share/meshbridge
echo "meshbridge removed"
EOF
	exit 0
fi

echo "== Checking the printer"
"${SSH[@]}" 'sh -s' <<'EOF'
set -e
grep -qs ' /kip ' /proc/mounts || { echo "ERROR: /kip (Kipware) isn't mounted: is this OpenCentauri's patched firmware?"; exit 1; }
[ -x /kip/bin/python3 ] || { echo "ERROR: /kip/bin/python3 is missing"; exit 1; }
[ -d /kip/etc/init.d ] || { echo "ERROR: /kip/etc/init.d is missing"; exit 1; }
echo "Kipware OK, $(/kip/bin/python3 --version 2>&1)"
EOF

echo "== Copying meshbridge.py"
"${SSH[@]}" 'mkdir -p /kip/share/meshbridge && cat > /kip/share/meshbridge/meshbridge.py' < "$SRC"

echo "== Installing the boot script /kip/etc/init.d/S90meshbridge"
"${SSH[@]}" 'cat > /kip/etc/init.d/S90meshbridge && chmod 755 /kip/etc/init.d/S90meshbridge' <<'EOF'
#!/bin/sh
# meshbridge: serves the saved bed mesh to PrintDeck on port 7140 (installed by PrintDeck's
# tools/install-meshbridge.sh). Started at boot by /kip/etc/init.d/rc.unslung (OpenCentauri's oc-bootstrap).
PORT=7140
PY=/kip/bin/python3
SCRIPT=/kip/share/meshbridge/meshbridge.py
PIDFILE=/tmp/meshbridge.pid
LOG=/tmp/meshbridge.log

running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

case "$1" in
	start)
		if running; then echo "meshbridge already running"; exit 0; fi
		# A supervisor loop: if Python ever exits, start it again after a few seconds.
		( trap 'kill $child 2>/dev/null; exit 0' TERM INT
		  while true; do
			"$PY" "$SCRIPT" --port "$PORT" >>"$LOG" 2>&1 &
			child=$!
			wait $child
			echo "meshbridge exited ($?), restarting in 5 s" >>"$LOG"
			sleep 5
		  done ) </dev/null >/dev/null 2>&1 &
		echo $! > "$PIDFILE"
		echo "meshbridge started on port $PORT"
		;;
	stop)
		if running; then kill "$(cat "$PIDFILE")"; fi
		rm -f "$PIDFILE"
		pkill -f "$SCRIPT" 2>/dev/null || true
		echo "meshbridge stopped"
		;;
	restart) "$0" stop; sleep 1; "$0" start ;;
	check|status) if running; then echo "alive"; else echo "dead"; exit 1; fi ;;
	*) echo "Usage: $0 {start|stop|restart|check}"; exit 1 ;;
esac
EOF

echo "== Starting it"
"${SSH[@]}" '/kip/etc/init.d/S90meshbridge restart; sleep 3; /kip/etc/init.d/S90meshbridge check; tail -5 /tmp/meshbridge.log'

echo "== Asking it for the mesh from here"
if curl -s -m 5 "http://$IP:7140/" ; then echo; echo "meshbridge is answering. It will start again at every boot."
else echo "WARNING: no answer on http://$IP:7140/ yet: see /tmp/meshbridge.log on the printer"; exit 1; fi
