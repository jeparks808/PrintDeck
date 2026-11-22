#!/usr/bin/env bash
# Back up an OpenCentauri (patched) Centauri Carbon before trying COSMOS.
# Read-only on the printer: it only runs cat/ls/tar/dd *from* the printer to this computer.
#
#   tools/backup-printer.sh [printer-ip] [--full]
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
for a in "$@"; do
	case "$a" in
		--full) FULL=1 ;;
		*) IP="$a" ;;
	esac
done

OUT="$HOME/printer-backups/$IP-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
SOCK="$OUT/.ssh-ctl"
SSH=(ssh -o ControlMaster=auto -o ControlPath="$SOCK" -o ControlPersist=600
     -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "root@$IP")
cleanup() { ssh -o ControlPath="$SOCK" -O exit "root@$IP" 2>/dev/null || true; rm -f "$SOCK"; }
trap cleanup EXIT

echo "== Backing up $IP into $OUT"
"${SSH[@]}" true    # the one password prompt; later commands reuse this connection

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
