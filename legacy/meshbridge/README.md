# meshbridge

Serves the Centauri Carbon's saved **bed mesh** to PrintDeck over plain HTTP, for printers on
OpenCentauri's **patched** firmware (which has no Moonraker and no network Klipper API).

The patched firmware is a monolithic Klippy, but it saves its bed meshes as standard Klipper
`[bed_mesh …]` profiles in `/board-resource/user_printer.cfg` (and `printer.cfg`). `meshbridge` reads
those files and serves the mesh as the JSON PrintDeck's mesh page fetches. It only ever **reads** them.

```
GET /mesh[?profile=NAME]   -> {"nx","ny","min":[x,y],"max":[x,y],"z":[[...]],"profile":NAME}
GET /                      -> {"default":NAME, "profiles":[{"name","nx","ny","range"}...]}
```

## Run it on the printer

The printer has Python 3 at `/kip/bin/python3`. OpenCentauri's default SSH login is user `root`, password
`OpenCentauri` (case sensitive); change it with `passwd` once you're in. Copy the script over and start it:

```bash
scp -O meshbridge.py root@<printer-ip>:/tmp/        # password: OpenCentauri (the default)
ssh root@<printer-ip> '/kip/bin/python3 /tmp/meshbridge.py --port 7140'
```

It prints the profiles it found and serves on `0.0.0.0:7140`. Leave it running, or see "Start on boot" to install it permanently.

## Point PrintDeck at it

On the iPad, open the deep link (URL-encode the helper URL):

```
printdeck://mesh?helper=http%3A%2F%2F<printer-ip>%3A7140%2Fmesh
```

PrintDeck remembers the helper URL, so after that the mesh page's **Refresh** re-fetches, and `••• → Bed
mesh` or the Bed detail page's **Bed mesh** button open it. A specific profile:
`…%2Fmesh%3Fprofile%3Dbed_mesh%20cool`.

## Which mesh it serves

`/mesh` returns the profile named `default` if present, else the highest-resolution one. The firmware
keeps several (per build plate / bed temp). `GET /` lists them; pass `?profile=NAME` to pick one.
`meshbridge` re-reads the files on every request, so running `BED_MESH_CALIBRATE` + saving on the
printer and then tapping **Refresh** shows the new mesh.

## Start on boot

`tools/install-meshbridge.sh [printer-ip]` (in the PrintDeck repo) does it all: it asks for the root password
once, copies the script to `/kip/share/meshbridge/meshbridge.py`, and installs `/kip/etc/init.d/S90meshbridge`.
OpenCentauri's boot script (`/etc/init.d/oc-bootstrap`) mounts Kipware from the persistent `/user-resource`
partition on `/kip` and runs `/kip/etc/init.d/rc.unslung start`, which starts every `S??*` script there, so
meshbridge comes up at every power-on, survives firmware updates, and is restarted if it exits. On the printer:
`/kip/etc/init.d/S90meshbridge start|stop|restart|check`; its log is `/tmp/meshbridge.log`.
`tools/install-meshbridge.sh <ip> --remove` takes it out again.

## Test off-device

Point it at any file with `[bed_mesh …]` profiles:

```bash
MESHBRIDGE_CFG=./sample.cfg python3 meshbridge.py --port 7140
```

## Security note

`meshbridge` listens on all interfaces with no auth (like the printer's other services). It is
read-only and exposes only mesh numbers, but anyone on your LAN can read them while it runs.
