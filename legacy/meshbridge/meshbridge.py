#!/usr/bin/env python3
"""meshbridge — serve the Elegoo Centauri Carbon's saved bed mesh to PrintDeck over plain HTTP.

The Centauri's OpenCentauri *patched* firmware has no Moonraker and no network Klipper API, but it saves
its bed meshes as Klipper `[bed_mesh …]` profiles in /board-resource/user_printer.cfg (and printer.cfg).
This reads those files and serves the mesh as the JSON PrintDeck expects:

    GET /mesh[?profile=NAME]   -> {"nx","ny","min":[x,y],"max":[x,y],"z":[[...]],"profile":NAME}
    GET /                      -> {"profiles":[{"name","nx","ny","range"}...], "default": NAME}

Run it on the printer (python3 is at /kip/bin/python3):

    /kip/bin/python3 meshbridge.py                 # serve on 0.0.0.0:7140
    /kip/bin/python3 meshbridge.py --port 7140

Then in PrintDeck open  printdeck://mesh?helper=http%3A%2F%2F<printer-ip>%3A7140%2Fmesh  (or set the
helper URL and tap Refresh). It only ever *reads* the config files.
"""
import argparse, json, math, os, re
try:
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from urllib.parse import urlparse, parse_qs
except ImportError:  # very old python3
    from BaseHTTPServer import BaseHTTPRequestHandler, HTTPServer
    from urlparse import urlparse, parse_qs

CFG_PATHS = ["/board-resource/user_printer.cfg", "/board-resource/printer.cfg"]
if os.environ.get("MESHBRIDGE_CFG"):   # for testing off-device
    CFG_PATHS = [os.environ["MESHBRIDGE_CFG"]]


def _nums(s):
    out = []
    for tok in s.replace(",", " ").split():
        try:
            out.append(float(tok))
        except ValueError:
            pass
    return out


def parse_profiles(text):
    """Every config section that carries a `points` key becomes a profile."""
    lines = text.splitlines()
    profiles, section, cur = [], None, None
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        if s.startswith("[") and s.endswith("]"):
            section = s[1:-1].strip()
            cur = None
            i += 1
            continue
        low = s.lower()
        key = re.split(r"[:=]", low, 1)[0].strip() if (":" in s or "=" in s) else ""
        if key == "points":
            after = re.split(r"[:=]", s, 1)[1]
            pts = _nums(after)
            j = i + 1
            while j < len(lines):  # standard Klipper continues points onto indented number rows
                t = lines[j].strip()
                if t and not re.search(r"[A-Za-z\[]", t) and _nums(t):
                    pts += _nums(t)
                    j += 1
                else:
                    break
            cur = {"name": section or "mesh", "points": pts, "x": 0, "y": 0, "min": None, "max": None}
            profiles.append(cur)
            i = j
            continue
        if cur is not None and key in ("x_count", "y_count", "mesh_min", "mesh_max", "min_x", "max_x", "min_y", "max_y"):
            v = _nums(re.split(r"[:=]", s, 1)[1])
            if key == "x_count" and v:
                cur["x"] = int(v[0])
            elif key == "y_count" and v:
                cur["y"] = int(v[0])
            elif key == "mesh_min" and len(v) >= 2:
                cur["min"] = (v[0], v[1])
            elif key == "mesh_max" and len(v) >= 2:
                cur["max"] = (v[0], v[1])
            elif key in ("min_x", "min_y", "max_x", "max_y") and v:
                mn = list(cur["min"] or (0.0, 0.0))
                mx = list(cur["max"] or (0.0, 0.0))
                {"min_x": lambda: mn.__setitem__(0, v[0]), "min_y": lambda: mn.__setitem__(1, v[0]),
                 "max_x": lambda: mx.__setitem__(0, v[0]), "max_y": lambda: mx.__setitem__(1, v[0])}[key]()
                cur["min"], cur["max"] = tuple(mn), tuple(mx)
        i += 1
    return [p for p in profiles if len(p["points"]) >= 4]


def to_mesh(p):
    pts, x, y = p["points"], p["x"], p["y"]
    if x <= 0 and y <= 0:
        x = y = int(round(math.sqrt(len(pts))))
    elif x <= 0:
        x = len(pts) // max(1, y)
    elif y <= 0:
        y = len(pts) // max(1, x)
    if x < 2 or y < 2 or x * y > len(pts):
        return None
    mn = p["min"] or (0.0, 0.0)
    mx = p["max"] or (float(x - 1), float(y - 1))
    z = [[pts[r * x + c] for c in range(x)] for r in range(y)]  # row 0 = min Y, col 0 = min X (Klipper order)
    return {"nx": x, "ny": y, "min": [mn[0], mn[1]], "max": [mx[0], mx[1]], "z": z, "profile": p["name"]}


def load_meshes():
    meshes = {}
    for path in CFG_PATHS:
        if not os.path.exists(path):
            continue
        try:
            with open(path, "r", errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        for p in parse_profiles(text):
            m = to_mesh(p)
            if m and m["profile"] not in meshes:  # first file (user_printer.cfg) wins
                meshes[m["profile"]] = m
        if meshes:
            break
    return meshes


def pick_default(meshes):
    if not meshes:
        return None
    for name in meshes:
        if "default" in name.lower():
            return name
    return max(meshes, key=lambda n: len(meshes[n]["z"]) * len(meshes[n]["z"][0]))  # most points


class Handler(BaseHTTPRequestHandler):
    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        meshes = load_meshes()  # re-read each request, so a fresh calibration shows up on Refresh
        if not meshes:
            return self._send({"error": "no bed_mesh profile found in the config"}, 404)
        if u.path.rstrip("/") in ("", "/list"):
            default = pick_default(meshes)
            rng = lambda m: round(max(max(r) for r in m["z"]) - min(min(r) for r in m["z"]), 4)
            return self._send({"default": default,
                               "profiles": [{"name": n, "nx": m["nx"], "ny": m["ny"], "range": rng(m)} for n, m in meshes.items()]})
        if u.path.startswith("/mesh"):
            q = parse_qs(u.query)
            name = q.get("profile", [None])[0] or pick_default(meshes)
            m = meshes.get(name) or meshes[pick_default(meshes)]
            return self._send(m)
        self._send({"error": "not found"}, 404)

    def log_message(self, *a):
        pass  # quiet


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7140)
    ap.add_argument("--host", default="0.0.0.0")
    a = ap.parse_args()
    meshes = load_meshes()
    print("meshbridge: %d profile(s) found: %s" % (len(meshes), ", ".join(meshes) or "(none yet)"), flush=True)
    print("serving on %s:%d  (GET /mesh, GET /)" % (a.host, a.port), flush=True)
    HTTPServer((a.host, a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
