#!/usr/bin/env bash
# Back up an OpenCentauri (patched) Centauri Carbon before trying COSMOS.
# Read-only on the printer: it only runs cat/ls/tar/dd *from* the printer to this computer.
#
#   tools/backup-printer.sh [printer-ip] [--full] [--wait-idle]
#
# --wait-idle: ask for the password first, then wait until the printer is idle (no print, no bed levelling or
# other touchscreen job, read over SDCP), plus 20 seconds, before copying anything. Start it during levelling.
#
# Default: system info + every config/calibration file (/board-resource, /user-resource, /etc, ...).
# --full also images every eMMC partition (dd over SSH, gzip here). That takes a while (several GB
# over Wi-Fi) but is the only thing that can rebuild the printer exactly if all else fails (UART/FEL).
#
# SSH asks for the root password once (OpenCentauri's default is documented in its docs; if you never
# changed it, this is a good moment to). Output: ~/printer-backups/<ip>-<date>/
set -euo pipefail

IP=192.168.0.185
FULL=0
WAIT=0
for a in "$@"; do
	case "$a" in
		--full) FULL=1 ;;
		--wait-idle) WAIT=1 ;;
		*) IP="$a" ;;
	esac
done

OUT="$HOME/printer-backups/$IP-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
SOCK="$OUT/.ssh-ctl"
SSH=(ssh -o ControlMaster=auto -o ControlPath="$SOCK" -o ControlPersist=yes -o ServerAliveInterval=30
     -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "root@$IP")
cleanup() { ssh -o ControlPath="$SOCK" -O exit "root@$IP" 2>/dev/null || true; rm -f "$SOCK"; }
trap cleanup EXIT

echo "== Backing up $IP into $OUT"
"${SSH[@]}" true    # the one password prompt; later commands reuse this connection

if [ "$WAIT" = 1 ]; then
	echo "== Waiting for the printer to be idle (Ctrl-C to give up)"
	# Read-only SDCP status (Cmd 0). Idle = CurrentStatus all 0 and PrintInfo.Status 0, seen twice in a row.
	python3 -I - "$IP" <<'PY'
import asyncio, json, sys, time, uuid
import websockets
ip = sys.argv[1]
async def status():
    async with websockets.connect(f"ws://{ip}:3030/websocket", max_size=None, open_timeout=10) as ws:
        await ws.send(json.dumps({"Id": "", "Data": {"Cmd": 0, "Data": {}, "RequestID": uuid.uuid4().hex,
                                  "MainboardID": "", "TimeStamp": 0, "From": 1}}))
        end = time.time() + 8
        while time.time() < end:
            try: j = json.loads(await asyncio.wait_for(ws.recv(), 2))
            except asyncio.TimeoutError: continue
            if isinstance(j.get("Status"), dict): return j["Status"]
idle_seen, last = 0, None
while idle_seen < 2:
    try:
        s = asyncio.run(status()); msg = "no status reply"
    except Exception as e:
        s = None; msg = f"no answer ({e.__class__.__name__})"
    if s:
        cs = s.get("CurrentStatus") or [0]; ps = (s.get("PrintInfo") or {}).get("Status", 0)
        idle = all(c == 0 for c in cs) and ps == 0
        msg = "idle" if idle else f"busy (CurrentStatus {cs}, PrintInfo.Status {ps})"
        idle_seen = idle_seen + 1 if idle else 0
    if msg != last: print(time.strftime("   %H:%M:%S"), msg, flush=True); last = msg
    if idle_seen < 2: time.sleep(10)
PY
	echo "   idle; waiting 20 s more"
	sleep 20
fi

echo "== System info"
"${SSH[@]}" 'sh -s' >"$OUT/system-info.txt" 2>&1 <<'EOF' || true
echo "### date";        date
echo "### uname";       uname -a
echo "### os-release";  cat /etc/os-release 2>/dev/null
echo "### versions";    cat /etc/version* /etc/*_version /app/version* 2>/dev/null
echo "### cmdline";     cat /proc/cmdline
echo "### partitions";  cat /proc/partitions
echo "### by-name";     ls -l /dev/by-name/ 2>/dev/null
echo "### bootenv";     fw_printenv 2>/dev/null
echo "### mounts";      cat /proc/mounts
echo "### df";          df -h
echo "### processes";   ps w 2>/dev/null || ps
echo "### listening";   netstat -lntup 2>/dev/null
EOF
grep -E '^(boot_partition|root_partition|dsp0_partition|swu_mode)=' "$OUT/system-info.txt" || true

echo "== Config, calibration and bed-mesh files"
# Whatever of these exists; missing paths are skipped. Compressed here, not on the printer's small CPU.
"${SSH[@]}" 'cd / && P=""; for p in board-resource user-resource etc opt/oc mnt/UDISK/printer_data root; do
	[ -e "/$p" ] && P="$P $p"; done; tar -cf - $P 2>/dev/null' | gzip -6 >"$OUT/config-files.tar.gz"
tar -tzf "$OUT/config-files.tar.gz" >"$OUT/config-files.list"
echo "   $(wc -l <"$OUT/config-files.list") files"
for f in board-resource/user_printer.cfg board-resource/printer.cfg user-resource/filament_info; do
	grep -qx "$f" "$OUT/config-files.list" && echo "   has $f" || echo "   (no $f)"
done

if [ "$FULL" = 1 ]; then
	echo "== Full eMMC partition images (this is the slow part)"
	mkdir -p "$OUT/partitions"
	for part in $("${SSH[@]}" 'ls /dev/by-name/'); do
		echo "   $part"
		"${SSH[@]}" "dd if=/dev/by-name/$part bs=1M 2>/dev/null" | gzip -1 >"$OUT/partitions/$part.img.gz"
	done
	# The ~20 MB before the first partition holds the partition table and Allwinner's boot0/U-Boot, which no
	# by-name partition covers. A UART/FEL restore needs it.
	echo "   mmcblk0 start (partition table + bootloader)"
	"${SSH[@]}" "dd if=/dev/mmcblk0 bs=1M count=32 2>/dev/null" | gzip -1 >"$OUT/partitions/mmcblk0-first32M.img.gz"
fi

echo "== Checksums"
( cd "$OUT" && find . -type f ! -name SHA256SUMS ! -name '.ssh-ctl' -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS )

FW="$HOME/printer-backups/opencentauri-firmware/update.swu"
if [ -f "$FW" ]; then
	echo "== OpenCentauri patched firmware image is kept at $FW"
else
	echo "!! No OpenCentauri update.swu at $FW — download the patched firmware you're on and keep it there."
fi
echo "Done: $OUT"
du -sh "$OUT"
