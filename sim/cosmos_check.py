#!/usr/bin/env python3
"""Walk every PrintDeck feature against a COSMOS printer (the virtual one in cosmos_sim.py, or a real one later):
  1. the way PrintDeck does it today (Elegoo SDCP), to see what breaks;
  2. the Moonraker way a COSMOS backend would do it;
  3. what COSMOS adds that SDCP never had.
Read-only on a real printer unless --write is given (then it also changes temperatures, moves, prints...).

  python3 -I sim/cosmos_check.py [--host 127.0.0.1] [--port 17125] [--sdcp-port 3030] [--write] [--json out.json]
"""
import argparse, base64, json, os, socket, struct, sys, time, urllib.error, urllib.parse, urllib.request, uuid

P = argparse.ArgumentParser()
P.add_argument("--host", default="127.0.0.1")
P.add_argument("--port", type=int, default=17125, help="Moonraker port (80 on the real COSMOS printer)")
P.add_argument("--sdcp-port", type=int, default=3030)
P.add_argument("--write", action="store_true", help="also run the commands that change the printer (always on for the sim)")
P.add_argument("--json", help="write the results here")
A = P.parse_args()
BASE = "http://%s:%d" % (A.host, A.port)
WRITE = A.write or A.host in ("127.0.0.1", "localhost")
RESULTS = []

def rec(group, feature, ok, how, note=""):
    RESULTS.append({"group": group, "feature": feature, "ok": ok, "how": how, "note": note})
    mark = {True: "PASS", False: "FAIL", None: "SKIP"}[ok]
    print("  [%s] %-34s %-46s %s" % (mark, feature, how, note))

def get(path, **q):
    url = BASE + path + ("?" + urllib.parse.urlencode(q, safe=",") if q else "")
    with urllib.request.urlopen(url, timeout=6) as r: return json.loads(r.read())["result"]

def post(path, body=None):
    req = urllib.request.Request(BASE + path, data=json.dumps(body or {}).encode(), headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r: return json.loads(r.read())["result"], None
    except urllib.error.HTTPError as e:
        try: return None, json.loads(e.read())["error"]["message"]
        except Exception: return None, str(e)

def gcode(script): return post("/printer/gcode/script", {"script": script})

def q(*objs):
    return get("/printer/objects/query", **{o: "" for o in objs})["status"]

def raw(path, nbytes=0, headers=None):
    req = urllib.request.Request(BASE + path, headers=headers or {})
    with urllib.request.urlopen(req, timeout=6) as r:
        return r.status, dict(r.headers), (r.read(nbytes) if nbytes else r.read())

# ---- a tiny websocket client (what PrintDeck's PDWebSocket.m does) -------------------------------------------
def ws_open(host, port, path="/websocket", timeout=4):
    s = socket.create_connection((host, port), timeout=timeout)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
               "Sec-WebSocket-Version: 13\r\n\r\n" % (path, host, port, key)).encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        c = s.recv(1024)
        if not c: raise ConnectionError("closed during handshake")
        resp += c
    if b" 101 " not in resp.split(b"\r\n")[0]: raise ConnectionError(resp.split(b"\r\n")[0].decode())
    return s

def ws_send(s, text):
    data = text.encode(); m = os.urandom(4); n = len(data)
    hdr = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0xFE]) + struct.pack(">H", n))
    s.sendall(hdr + m + bytes(c ^ m[i % 4] for i, c in enumerate(data)))

def ws_recv(s):
    def rd(n):
        b = b""
        while len(b) < n:
            c = s.recv(n - len(b))
            if not c: raise ConnectionError("closed")
            b += c
        return b
    b1, b2 = rd(2); n = b2 & 127
    if n == 126: n = struct.unpack(">H", rd(2))[0]
    elif n == 127: n = struct.unpack(">Q", rd(8))[0]
    return json.loads(rd(n))

def sdcp_msg(cmd, data=None):
    return json.dumps({"Id": "", "Data": {"Cmd": cmd, "Data": data or {}, "RequestID": uuid.uuid4().hex, "MainboardID": "",
                                          "TimeStamp": int(time.time()), "From": 1}, "Topic": "sdcp/request/"})

# =============================================================================================================
print("\n== 1. The SDCP-only PrintDeck (before COSMOS support) against %s" % A.host)
try:
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.settimeout(2)
    u.sendto(b"M99999", (A.host, 3000)); u.recvfrom(4096); rec("today", "Discovery (UDP 3000 M99999)", True, "PDDiscovery")
except OSError:
    rec("today", "Discovery (UDP 3000 M99999)", False, "PDDiscovery", "no answer: the app can't find the printer by itself")
try:
    s = ws_open(A.host, A.sdcp_port); ws_send(s, sdcp_msg(0)); ws_recv(s); rec("today", "SDCP websocket :%d" % A.sdcp_port, True, "PDPrinter")
except OSError as e:
    rec("today", "SDCP websocket :%d" % A.sdcp_port, False, "PDPrinter", "connection refused (%s): app shows Offline" % e.__class__.__name__)
try:
    s = ws_open(A.host, A.port); ws_send(s, sdcp_msg(0)); r = ws_recv(s)
    if "error" in r:
        rec("today", "SDCP Cmd 0 to Moonraker /websocket", False, "PDPrinter (host:%d)" % A.port,
            "handshake OK, then JSON-RPC error '%s': never gets a status, reconnects every 8 s" % r["error"]["message"])
    else:
        rec("today", "SDCP Cmd 0 to Moonraker /websocket", False, "PDPrinter", "unexpected reply: %s" % str(r)[:80])
except OSError as e:
    rec("today", "SDCP Cmd 0 to Moonraker /websocket", False, "PDPrinter", str(e))
try:
    socket.create_connection((A.host, 3031), timeout=2).close(); rec("today", "Camera MJPEG :3031/video", True, "PDMJPEGView")
except OSError:
    rec("today", "Camera MJPEG :3031/video", False, "PDMJPEGView", "nothing on 3031")
try:
    raw("/local/" + "x.gcode", 10); rec("today", "G-code download /local/<file>", True, "PDToolpath")
except Exception:
    rec("today", "G-code download /local/<file>", False, "PDToolpath", "404: files live under /server/files/gcodes/")

# =============================================================================================================
print("\n== 2. Every PrintDeck feature, done the Moonraker way")
info = get("/printer/info"); objs = get("/printer/objects/list")["objects"]
rec("moonraker", "Connect + printer name/state", info["state"] == "ready", "GET /printer/info", "%s, %s" % (info["hostname"], info["software_version"]))
def has(o): return o in objs
chamber = next((o for o in objs if o.startswith("temperature_sensor") and "chamber" in o), None)
st = q("extruder", "heater_bed", chamber or "extruder", "print_stats", "virtual_sdcard", "fan", "gcode_move", "toolhead")
rec("moonraker", "Nozzle / bed temperature", "temperature" in st["extruder"] and "temperature" in st["heater_bed"],
    "objects/query extruder, heater_bed", "%.1f / %.1f °C" % (st["extruder"]["temperature"], st["heater_bed"]["temperature"]))
rec("moonraker", "Chamber temperature", bool(chamber), "objects/query %s" % chamber, "display only (no chamber heater)")
ts = get("/server/temperature_store")
rec("moonraker", "Temperature graphs (history)", len(ts.get("extruder", {}).get("temperatures", [])) > 0,
    "GET /server/temperature_store", "1 s samples, 20 min kept by the printer")
rec("moonraker", "Job: state / progress / layer", "state" in st["print_stats"],
    "print_stats + virtual_sdcard", "state=%s, layer from print_stats.info" % st["print_stats"]["state"])
rec("moonraker", "Position (Move page)", len(st["toolhead"]["position"]) == 4, "toolhead.position, homed_axes", "homed=%r" % st["toolhead"]["homed_axes"])
try:
    sc, hd, body = raw("/webcam/?action=stream", 4096)
    rec("moonraker", "Camera", b"image/jpeg" in body, "GET /webcam/?action=stream", "MJPEG (%s)" % hd.get("Content-Type", "")[:40])
except Exception as e:
    rec("moonraker", "Camera", False, "GET /webcam/?action=stream", str(e))
files = get("/server/files/list", root="gcodes")
rec("moonraker", "File list", len(files) > 0, "GET /server/files/list?root=gcodes", "%d files" % len(files))
clean = [f["path"] for f in files if "PrintDeck" not in f["path"]]
f0 = clean[0] if clean else (files[0]["path"] if files else "")
meta = get("/server/files/metadata", filename=f0) if f0 else {}
rec("moonraker", "File details (Cmd 260 equivalent)", "estimated_time" in meta, "GET /server/files/metadata",
    "layers=%s est=%ss slicer=%s" % (meta.get("layer_count"), meta.get("estimated_time"), meta.get("slicer")))
try:
    sc, hd, body = raw("/server/files/gcodes/" + urllib.parse.quote(f0), 0, {"Range": "bytes=0-98303"})
    rec("moonraker", "G-code download (3D view, thumbs)", sc in (200, 206) and len(body) > 0, "GET /server/files/gcodes/<file>",
        "Range works (%d bytes)" % len(body) if sc == 206 else "no Range: full download")
except Exception as e:
    rec("moonraker", "G-code download (3D view, thumbs)", False, "GET /server/files/gcodes/<file>", str(e))
th = meta.get("thumbnails") or []
if th:
    try:
        sc, hd, body = raw("/server/files/gcodes/" + urllib.parse.quote(th[-1]["relative_path"]))
        rec("moonraker", "File thumbnail", body[:4] == b"\x89PNG", "GET /server/files/gcodes/.thumbs/…", "%dx%d PNG" % (th[-1]["width"], th[-1]["height"]))
    except Exception as e:
        rec("moonraker", "File thumbnail", False, "thumbnails", str(e))
hist = get("/server/history/list", limit=5)
rec("moonraker", "Last job / outcome", "jobs" in hist, "GET /server/history/list", "%d jobs" % hist["count"])
lanes = [o for o in objs if o.startswith("AFC_lane ")]
ls = q(*lanes) if lanes else {}
rec("moonraker", "CANVAS slots (read)", len(lanes) == 4, "objects/query AFC, AFC_lane CANVAS_1..4",
    ", ".join("%s %s %s" % (n.split()[1], v["material"], v["color"]) for n, v in ls.items()))
bm = q("bed_mesh")["bed_mesh"]
rec("moonraker", "Bed mesh (no meshbridge needed)", bool(bm.get("probed_matrix") and bm["probed_matrix"][0]), "objects/query bed_mesh",
    "%dx%d, profile %r" % (len(bm["probed_matrix"]), len(bm["probed_matrix"][0]) if bm["probed_matrix"] else 0, bm["profile_name"]))

if WRITE:
    def check(feature, script, how, verify, note=""):
        _, err = gcode(script); time.sleep(0.35)
        ok = err is None and verify()
        rec("moonraker", feature, ok, how, err or note)
    check("Set nozzle temperature", "M104 S200", "gcode M104 S200", lambda: q("extruder")["extruder"]["target"] == 200)
    check("Set bed temperature", "M140 S60", "gcode M140 S60", lambda: q("heater_bed")["heater_bed"]["target"] == 60)
    check("Cool down", "M104 S0\nM140 S0", "gcode M104 S0 / M140 S0", lambda: q("extruder")["extruder"]["target"] == 0)
    check("Part fan", "M106 S128", "gcode M106 S128", lambda: abs(q("fan")["fan"]["speed"] - 0.5) < 0.01)
    gfans = [o.split(" ", 1)[1] for o in objs if o.startswith("fan_generic ")]
    for g in gfans:
        check("Fan '%s'" % g, "SET_FAN_SPEED FAN=%s SPEED=0.4" % g, "SET_FAN_SPEED FAN=%s" % g,
              lambda g=g: abs(q("fan_generic " + g)["fan_generic " + g]["speed"] - 0.4) < 0.01, "name is per-printer: discover it")
    check("Print speed % (any value)", "M220 S125", "gcode M220 S125", lambda: abs(q("gcode_move")["gcode_move"]["speed_factor"] - 1.25) < 1e-6,
          "SDCP only took 50/100/130/160")
    leds = [o.split(" ", 1)[1] for o in objs if o.startswith("led ")]
    if leds:
        check("Light (with brightness)", "SET_LED LED=%s WHITE=0.6" % leds[0], "SET_LED LED=%s WHITE=…" % leds[0],
              lambda: q("led " + leds[0])["led " + leds[0]]["color_data"][0][3] == 0.6)
    check("Home all", "G28", "gcode G28", lambda: q("toolhead")["toolhead"]["homed_axes"] == "xyz")
    check("Jog X +10", "G91\nG1 X10 F6000\nG90", "G91 / G1 X10 / G90", lambda: abs(q("toolhead")["toolhead"]["position"][0] - 10) < 1e-6)
    # print control
    _, err = post("/printer/print/start", {"filename": f0}); time.sleep(0.5)
    rec("moonraker", "Start print", err is None and q("print_stats")["print_stats"]["state"] == "printing", "POST /printer/print/start", err or f0[:40])
    _, err = post("/printer/print/pause"); time.sleep(0.4)
    rec("moonraker", "Pause", err is None and q("print_stats")["print_stats"]["state"] == "paused", "POST /printer/print/pause", err or "")
    _, err = post("/printer/print/resume"); time.sleep(0.4)
    rec("moonraker", "Resume", err is None and q("print_stats")["print_stats"]["state"] == "printing", "POST /printer/print/resume", err or "")
    _, err = post("/printer/print/cancel"); time.sleep(0.4)
    rec("moonraker", "Stop", err is None and q("print_stats")["print_stats"]["state"] == "cancelled", "POST /printer/print/cancel", err or "")
    # upload, as the Slice page does
    bnd = uuid.uuid4().hex; good = b"; generated by ElegooSlicer\nG28\nM104 S0\n"
    body = (b"--%s\r\nContent-Disposition: form-data; name=\"root\"\r\n\r\ngcodes\r\n--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"printdeck_upload_test.gcode\"\r\n"
            b"Content-Type: application/octet-stream\r\n\r\n%s\r\n--%s--\r\n" % (bnd.encode(), bnd.encode(), good, bnd.encode()))
    req = urllib.request.Request(BASE + "/server/files/upload", data=body, headers={"Content-Type": "multipart/form-data; boundary=" + bnd})
    try:
        with urllib.request.urlopen(req, timeout=8) as r: up = json.loads(r.read())
        rec("moonraker", "Upload (Slice page)", up["item"]["path"] == "printdeck_upload_test.gcode", "POST /server/files/upload (multipart)",
            "one request; no MD5/chunk protocol")
    except Exception as e:
        rec("moonraker", "Upload (Slice page)", False, "POST /server/files/upload", str(e))
    req = urllib.request.Request(BASE + "/server/files/gcodes/printdeck_upload_test.gcode", method="DELETE")
    try:
        urllib.request.urlopen(req, timeout=5).read(); rec("moonraker", "Delete file", True, "DELETE /server/files/gcodes/<file>")
    except Exception as e:
        rec("moonraker", "Delete file", False, "DELETE /server/files/gcodes/<file>", str(e))
    # websocket push instead of polling
    try:
        s = ws_open(A.host, A.port); s.settimeout(3)
        ws_send(s, json.dumps({"jsonrpc": "2.0", "method": "printer.objects.subscribe", "id": 1,
                               "params": {"objects": {"extruder": ["temperature", "target"], "print_stats": None}}}))
        first = ws_recv(s); gcode("M104 S180"); got = None; t0 = time.time()
        while time.time() - t0 < 3:
            m = ws_recv(s)
            if m.get("method") == "notify_status_update" and "target" in m["params"][0].get("extruder", {}): got = m; break
        rec("moonraker", "Live push instead of 2 s polling", got is not None, "ws printer.objects.subscribe", "notify_status_update")
        gcode("M104 S0"); s.close()
    except Exception as e:
        rec("moonraker", "Live push instead of 2 s polling", False, "ws printer.objects.subscribe", str(e))

# =============================================================================================================
print("\n== 3. New with COSMOS (SDCP had none of these)")
if WRITE:
    _, err = gcode("SET_COLOR LANE=CANVAS_2 COLOR=FF8800\nSET_MATERIAL LANE=CANVAS_2 MATERIAL=PETG"); time.sleep(0.3)
    l2 = q("AFC_lane CANVAS_2")["AFC_lane CANVAS_2"]
    rec("cosmos", "CANVAS slot write (colour, material)", err is None and l2["color"] == "#FF8800" and l2["material"] == "PETG",
        "SET_COLOR / SET_MATERIAL LANE=CANVAS_2", err or "brand/name need Spoolman (not in COSMOS)")
    check_new = [
        ("Z offset (baby-stepping)", "SET_GCODE_OFFSET Z_ADJUST=0.02 MOVE=1", lambda: abs(q("gcode_move")["gcode_move"]["homing_origin"][2] - 0.02) < 1e-6),
        ("Motors off", "M84", lambda: not any(q("stepper_enable")["stepper_enable"]["steppers"].values())),
        ("Re-probe bed mesh", "BED_MESH_CALIBRATE", lambda: q("bed_mesh")["bed_mesh"]["profile_name"] == "default"),
        ("Any G-code / macro", "CHECK_CALIBRATION", lambda: True),
    ]
    for feat, sc, ver in check_new:
        _, err = gcode(sc); time.sleep(0.3)
        rec("cosmos", feat, err is None and ver(), sc.split()[0], err or "")
    _, err = gcode("G91\nG1 E5 F300\nG90")
    rec("cosmos", "Extrude / retract", err is None, "G1 E±n (needs hot nozzle on a real printer)", err or "")
    gs = get("/server/gcode_store", count=20)["gcode_store"]
    rec("cosmos", "Console log", len(gs) > 0, "GET /server/gcode_store", "%d lines" % len(gs))
macros = [o.split(" ", 1)[1] for o in objs if o.startswith("gcode_macro ")]
rec("cosmos", "Macros as buttons", len(macros) > 0, "objects/list gcode_macro *", ", ".join(macros[:6]))

# =============================================================================================================
print("\n== 4. Compatibility of what PrintDeck's slicer writes")
bad = [f["path"] for f in files if "PrintDeck" in f["path"]]
if WRITE and bad:
    gcode("FIRMWARE_RESTART"); time.sleep(0.3)
    post("/printer/print/start", {"filename": bad[0]}); time.sleep(0.6)
    w = q("webhooks")["webhooks"]
    rec("compat", "Old PrintDeck-sliced file", w["state"] == "ready", "start G-code has M729 + M6211 (fixed in the slicer)",
        "Klipper %s: %s" % (w["state"].upper(), w["state_message"][:90]))
    gcode("FIRMWARE_RESTART")
else:
    rec("compat", "Old PrintDeck-sliced file", None, "", "needs --write")

ok = sum(1 for r in RESULTS if r["ok"]); bad_n = sum(1 for r in RESULTS if r["ok"] is False)
print("\n%d passed, %d failed, %d skipped" % (ok, bad_n, len(RESULTS) - ok - bad_n))
if A.json:
    with open(A.json, "w") as fh: json.dump(RESULTS, fh, indent=1)
