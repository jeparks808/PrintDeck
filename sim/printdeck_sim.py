#!/usr/bin/env python3
"""Simulated Elegoo Centauri Carbon (SDCP V3) for trying PrintDeck without tying up the real printer.

Serves the same three things the real printer does, on 127.0.0.1:
  BASE      websocket  /websocket   SDCP JSON (status, attributes, files, history, print control, 403 edits)
  BASE+1    MJPEG      /video       a drawn camera view of the part growing (only after Cmd 386 Enable:1, like the real printer)
  BASE+2    HTTP       /thumb/...   job thumbnails (the real printer serves these on port 80)
  BASE+2    HTTP       /mesh        a synthetic bed mesh in PrintDeck's JSON format (stands in for the mesh helper)
  BASE+2    HTTP       /local/...   synthetic G-code for each file (the real printer shares /local/ on port 80)

Scenarios (--scenario):
  printing   a job already 35% in (default)
  finish     a job 5 s from the end -> "Print finished"
  runout     a job that pauses itself at 40% (as on filament runout) -> "Print paused"
  idle       nothing printing; start one from Files
Time runs --speed times faster than real time (default 30). Standard library + Pillow only.
"""
import argparse, asyncio, base64, hashlib, io, json, math, struct, time, uuid
from PIL import Image, ImageDraw

P = argparse.ArgumentParser()
P.add_argument("--base", type=int, default=13030)
P.add_argument("--scenario", default="printing", choices=["printing", "finish", "runout", "idle"])
P.add_argument("--speed", type=float, default=30.0)
P.add_argument("--gcode-dir", help="serve real G-code files with the same base names from here instead of the synthetic ones")
A = P.parse_args()
WS_PORT, VIDEO_PORT, THUMB_PORT = A.base, A.base + 1, A.base + 2
MAINBOARD = "5151515151515151000000000000sim0"

FILES = [
    {"name": "/local/ECC_0.6_Kendama_Mount_SUNLU PLA _0.24_55m11s.gcode", "TotalLayers": 179, "FileSize": 4217128, "secs": 3311},
    {"name": "/local/ECC_0.6_adaptervent_hose_SUNLU PLA _0.24_2h18m.gcode", "TotalLayers": 291, "FileSize": 7209109, "secs": 8306},
    {"name": "/local/ECC_0.6_Benchy_Elegoo Rapid PETG _0.24_38m02s.gcode", "TotalLayers": 120, "FileSize": 2210000, "secs": 2282},
]

class Printer:
    def __init__(self):
        self.nozzle, self.bed, self.box = 26.0, 25.0, 25.0
        self.t_nozzle = self.t_bed = 0
        self.fans = {"ModelFan": 0, "AuxiliaryFan": 0, "BoxFan": 0}
        self.light = 1
        self.speed = 100
        self.state = 0          # PrintInfo.Status: 0 idle, 16 heating, 13 printing, 6 paused, 9 complete, 8 stopped
        self.job = None
        self.elapsed = 0.0
        self.progress = 0.0
        self.task_id = ""
        self.history = []
        self.pause_at = None
        self.pos = [0.0, 0.0, 0.0]   # toolhead position for jog/home while idle
        self.last = time.time()
        now = time.time()
        self.history.append(self.task_record(FILES[1], str(uuid.uuid4()), now - 30000, now - 16700, 1, 291, 0))

    def task_record(self, f, tid, begin, end, status, layers, reason):
        return {"Thumbnail": f"http://127.0.0.1:{THUMB_PORT}/thumb/{tid}.png", "TaskName": f["name"], "BeginTime": int(begin),
                "EndTime": int(end), "TaskStatus": status, "AlreadyPrintLayer": layers, "TaskId": tid, "ErrorStatusReason": reason,
                "SliceInformation": {"total_layer_numbers": f["TotalLayers"], "print_time": f["secs"]}}

    def start(self, name, progress=0.0):
        f = next((x for x in FILES if x["name"] == name), None)
        if not f or self.state not in (0, 8, 9):
            return 1 if f else 2
        self.job, self.progress, self.elapsed = f, progress, f["secs"] * progress * 1.25
        self.task_id = str(uuid.uuid4())
        self.begin = time.time() - self.elapsed
        self.history.insert(0, self.task_record(f, self.task_id, self.begin, 0, 0, 0, 0))
        self.t_nozzle, self.t_bed = 220, 60
        self.state = 16 if progress == 0 else 13
        if progress > 0:
            self.nozzle, self.bed = 219.6, 60.1
            self.fans["ModelFan"], self.fans["AuxiliaryFan"] = 100, 60
        return 0

    def finish(self, state, reason=0):
        self.state = state
        rec = self.history[0]
        rec.update(EndTime=int(time.time()), TaskStatus=1 if state == 9 else 2, AlreadyPrintLayer=self.layer(), ErrorStatusReason=reason)
        self.t_nozzle = self.t_bed = 0
        self.fans = {"ModelFan": 0, "AuxiliaryFan": 0, "BoxFan": 0}

    def layer(self):
        return int(round(self.progress * self.job["TotalLayers"])) if self.job else 0

    def step(self):
        if not getattr(self, "clock_started", False): return
        now = time.time(); dt = (now - self.last) * A.speed; self.last = now
        for attr, tgt, rate in (("nozzle", self.t_nozzle, 0.08), ("bed", self.t_bed, 0.02)):
            cur = getattr(self, attr); goal = tgt if tgt > 0 else 25.0
            setattr(self, attr, cur + (goal - cur) * min(1, rate * dt / 10) + (0.3 * math.sin(now * 1.7) if tgt else 0))
        self.box += ((30 if self.state == 13 else 25) - self.box) * min(1, 0.002 * dt)
        if self.state == 16 and abs(self.nozzle - self.t_nozzle) < 3:
            self.state = 13
            self.fans["ModelFan"], self.fans["AuxiliaryFan"] = 100, 60
        if self.state == 13:
            self.elapsed += dt
            self.progress = min(1.0, self.progress + dt * (self.speed / 100) / (self.job["secs"] * 1.25))
            if self.pause_at and self.progress >= self.pause_at:
                self.pause_at = None; self.state = 6
            if self.progress >= 1.0:
                self.finish(9)

    def status(self):
        machine = [1] if self.state in (13, 16, 6, 5) else [0]
        f = self.job or {"name": "", "TotalLayers": 0, "secs": 0}
        return {"Status": {
            "CurrentStatus": machine, "TimeLapseStatus": 0, "PlatFormType": 0, "AmsConnectStatus": 0,
            "TempOfHotbed": self.bed, "TempOfNozzle": self.nozzle, "TempOfBox": self.box,
            "TempTargetHotbed": self.t_bed, "TempTargetNozzle": self.t_nozzle, "TempTargetBox": 0,
            "CurrenCoord": ("110.00,64.00,%.2f" % (self.layer() * 0.24)) if self.state in (13, 16, 6, 5) else "%.2f,%.2f,%.2f" % tuple(self.pos), "CurrentFanSpeed": dict(self.fans), "ZOffset": 0,
            "LightStatus": {"SecondLight": self.light, "RgbLight": [0, 0, 0]},
            "PrintInfo": {"Status": self.state, "CurrentLayer": self.layer(), "TotalLayer": f["TotalLayers"],
                          "CurrentTicks": self.elapsed, "TotalTicks": f["secs"], "Filename": f["name"] if self.state else "",
                          "TaskId": self.task_id if self.state else "", "PrintSpeedPct": self.speed,
                          "Progress": int(self.progress * 100)}},
            "MainboardID": MAINBOARD, "TimeStamp": int(time.time()), "Topic": f"sdcp/status/{MAINBOARD}"}

PR = Printer()
if A.scenario == "printing": PR.start(FILES[0]["name"], 0.35)
elif A.scenario == "finish": PR.start(FILES[2]["name"], max(0.5, 1 - 25 * A.speed / (FILES[2]["secs"] * 1.25)))  # ends ~25 s after the app connects
elif A.scenario == "runout": PR.start(FILES[0]["name"], 0.38); PR.pause_at = 0.38 + 20 * A.speed / (FILES[0]["secs"] * 1.25)  # pauses ~20 s in

ATTRS = {"Attributes": {"Name": "Centauri Carbon (sim)", "MachineName": "Centauri Carbon", "BrandName": "ELEGOO", "ProtocolVersion": "V3.0.0",
         "FirmwareVersion": "V1.4.49-sim", "MainboardIP": "127.0.0.1", "MainboardID": MAINBOARD, "Capabilities": ["FILE_TRANSFER", "PRINT_CONTROL", "VIDEO_STREAM"],
         "MaximumVideoStreamAllowed": 4, "CameraStatus": 1,
         "DevicesStatus": {"SgStatus": 1, "ZMotorStatus": 1, "XMotorStatus": 1, "YMotorStatus": 1}}, "MainboardID": MAINBOARD, "Topic": f"sdcp/attributes/{MAINBOARD}"}

VIDEO_ON = False  # like the real printer: /video answers "camera not ready" until Cmd 386 {Enable: 1}

def response(cmd, data):
    return {"Id": "", "Data": {"Cmd": cmd, "Data": data, "RequestID": "", "MainboardID": MAINBOARD, "TimeStamp": int(time.time())},
            "Topic": f"sdcp/response/{MAINBOARD}"}

def handle(msg):
    d = msg.get("Data", {}); cmd = d.get("Cmd"); data = d.get("Data") or {}
    out = []
    if cmd == 0: out += [response(0, {"Ack": 0}), PR.status()]
    elif cmd == 1: out += [response(1, {"Ack": 0}), ATTRS]
    elif cmd == 386:
        global VIDEO_ON; VIDEO_ON = bool(data.get("Enable"))
        out.append(response(386, {"Ack": 0, "VideoUrl": f"127.0.0.1:{VIDEO_PORT}/video"} if VIDEO_ON else {"Ack": 0}))
    elif cmd == 258:
        out.append(response(258, {"Ack": 0, "FileList": [{"name": f["name"], "type": 1, "CreateTime": int(time.time()) - 3600 * (i + 1) * 7,
                    "FileSize": f["FileSize"], "TotalLayers": f["TotalLayers"]} for i, f in enumerate(FILES)]}))
    elif cmd == 320: out.append(response(320, {"Ack": 0, "HistoryData": [h["TaskId"] for h in PR.history]}))
    elif cmd == 321:
        ids = data.get("Id") or []
        out.append(response(321, {"Ack": 0, "HistoryDetailList": [h for h in PR.history if h["TaskId"] in ids]}))
    elif cmd == 128: out.append(response(128, {"Ack": PR.start(data.get("Filename", ""))}))
    elif cmd == 129:
        if PR.state == 13: PR.state = 6
        out.append(response(129, {"Ack": 0}))
    elif cmd == 131:
        if PR.state == 6: PR.state = 13
        out.append(response(131, {"Ack": 0}))
    elif cmd == 130:
        if PR.state in (13, 6, 16): PR.finish(8)
        out.append(response(130, {"Ack": 0}))
    elif cmd == 403:
        if "TempTargetNozzle" in data: PR.t_nozzle = int(data["TempTargetNozzle"])
        if "TempTargetHotbed" in data: PR.t_bed = int(data["TempTargetHotbed"])
        if "PrintSpeedPct" in data: PR.speed = int(data["PrintSpeedPct"])
        if "TargetFanSpeed" in data: PR.fans.update({k: int(v) for k, v in data["TargetFanSpeed"].items() if k in PR.fans})
        if "LightStatus" in data: PR.light = int(data["LightStatus"].get("SecondLight", PR.light))
        out.append(response(403, {"Ack": 0}))
    elif cmd in (401, 402):
        ok = PR.state in (0, 8, 9)
        if ok and cmd == 402:   # home: the named axes go to 0
            for i, ax in enumerate("XYZ"):
                if ax in data.get("Axis", ""): PR.pos[i] = 0.0
        elif ok:
            i = "XYZ".find(data.get("Axis", "")[:1])
            if i >= 0: PR.pos[i] = max(0.0, min(256.0, PR.pos[i] + float(data.get("Step", 0))))
        out.append(response(cmd, {"Ack": 0 if ok else 1}))
    elif cmd is not None: out.append(response(cmd, {"Ack": 0}))
    if cmd is not None and cmd != 0: print("cmd", cmd, json.dumps(data)[:120], flush=True)
    return out

# --- websocket server -----------------------------------------------------------------------------------------
async def ws_client(reader, writer):
    try:
        head = await reader.readuntil(b"\r\n\r\n")
        key = next(l.split(b":", 1)[1].strip() for l in head.split(b"\r\n") if l.lower().startswith(b"sec-websocket-key"))
        acc = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
        writer.write(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + acc + b"\r\n\r\n")
        print("websocket client connected", flush=True)
        if not getattr(PR, "clock_started", False):
            PR.clock_started = True; PR.last = time.time()  # scenario time starts when the app first connects
        while True:
            h = await reader.readexactly(2)
            op, n = h[0] & 0x0F, h[1] & 0x7F
            if n == 126: n = struct.unpack(">H", await reader.readexactly(2))[0]
            elif n == 127: n = struct.unpack(">Q", await reader.readexactly(8))[0]
            mask = await reader.readexactly(4) if h[1] & 0x80 else b"\0\0\0\0"
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(await reader.readexactly(n)))
            if op == 8: break
            if op != 1: continue
            if payload == b"ping": continue  # the real printer doesn't answer this either
            PR.step()
            for m in handle(json.loads(payload)):
                p = json.dumps(m).encode()
                hdr = bytes([0x81]) + (bytes([len(p)]) if len(p) < 126 else bytes([126]) + struct.pack(">H", len(p)) if len(p) < 65536 else bytes([127]) + struct.pack(">Q", len(p)))
                writer.write(hdr + p)
            await writer.drain()
    except (asyncio.IncompleteReadError, ConnectionError, StopIteration):
        pass
    finally:
        print("websocket client gone", flush=True)
        writer.close()

# --- camera + thumbnails --------------------------------------------------------------------------------------
def frame():
    PR.step()
    im = Image.new("RGB", (640, 360), (38, 32, 28)); d = ImageDraw.Draw(im)
    d.rectangle([0, 300, 640, 360], fill=(60, 60, 66))                       # bed
    for x in range(0, 640, 40): d.line([x, 300, x - 30, 360], fill=(70, 70, 78))
    h = int(150 * (PR.progress if PR.job else 0))
    if h: d.rectangle([250, 300 - h, 390, 300], fill=(60, 200, 90))          # the part
    t = time.time()
    nx = 320 + int(60 * math.sin(t * 3)) if PR.state == 13 else 470
    ny = 300 - h - 34
    d.rectangle([nx - 40, ny - 60, nx + 40, ny], fill=(30, 30, 34)); d.polygon([(nx - 8, ny), (nx + 8, ny), (nx, ny + 12)], fill=(255, 130, 80))
    d.text((12, 10), "SIMULATED CAMERA  " + time.strftime("%H:%M:%S"), fill=(220, 220, 220))
    b = io.BytesIO(); im.save(b, "JPEG", quality=70); return b.getvalue()

def thumb():
    im = Image.new("RGB", (240, 240), (28, 30, 36)); d = ImageDraw.Draw(im)
    d.ellipse([60, 40, 180, 100], fill=(60, 200, 90)); d.rectangle([60, 70, 180, 190], fill=(50, 180, 80)); d.ellipse([60, 160, 180, 220], fill=(60, 200, 90))
    b = io.BytesIO(); im.save(b, "PNG"); return b.getvalue()

def mesh_json():
    # A 7x7 bed with a saddle + one high corner, like a real-ish probe map (heights in mm over 20..200).
    import json as _json
    n, zs = 7, []
    for gy in range(n):
        v = gy / (n - 1) * 2 - 1
        row = []
        for gx in range(n):
            u = gx / (n - 1) * 2 - 1
            # a central dome (distinct from the app's built-in demo saddle), heights in mm
            row.append(round(0.10 * math.exp(-(u * u + v * v) * 1.3) - 0.045, 5))
        zs.append(row)
    return _json.dumps({"nx": n, "ny": n, "min": [20, 20], "max": [200, 200], "z": zs, "profile": "default"}).encode()

def gcode_for(name):
    """Orca-style G-code for a file in FILES: a twisted, flared rounded-square vase with one layer per TotalLayers,
    outer + inner walls and sparse infill, ;LAYER_CHANGE/;Z:/;TYPE: comments, relative E (M83). About 1-2 MB."""
    from urllib.parse import unquote
    name = unquote(name)
    if A.gcode_dir:
        import os
        real = os.path.join(A.gcode_dir, os.path.basename(name))
        if os.path.isfile(real):
            with open(real, "rb") as fh: return fh.read()
    f = next((x for x in FILES if x["name"] == name), None)
    if not f: return None
    n, lh, out = f["TotalLayers"], 0.24, []
    w = out.append
    w("; generated by printdeck_sim\n; total layer number: %d\nG90\nM83\nG28\n;TYPE:Custom\nG1 X10 Y-1 Z0.3 F6000\nG1 X120 E12 F1500\n" % n)
    for i in range(n):
        z = 0.3 + i * lh
        w(";LAYER_CHANGE\n;Z:%.2f\n;HEIGHT:%.2f\n" % (z, lh))
        h = i / max(1, n - 1)
        rot = h * 1.2
        for kind, inset in (("Outer wall", 0.0), ("Inner wall", 0.45)):
            w(";TYPE:%s\n" % kind)
            pts = []
            for k in range(73):
                a = k / 72 * 2 * math.pi
                r = 30 + 10 * math.sin(h * math.pi) - inset            # flares in the middle
                sq = 1 / max(abs(math.cos(a)), abs(math.sin(a))) ** 0.35  # rounded square
                pts.append((128 + r * sq * math.cos(a + rot), 128 + r * sq * math.sin(a + rot)))
            w("G1 X%.3f Y%.3f F12000\nG1 Z%.2f\n" % (pts[0][0], pts[0][1], z))
            for x, y in pts[1:]: w("G1 X%.3f Y%.3f E0.06\n" % (x, y))
        if i < 3 or i % 6 == 0:
            w(";TYPE:Sparse infill\n")
            for k in range(-20, 21, 5):
                w("G1 X%.3f Y%.3f F12000\nG1 X%.3f Y%.3f E1.2\n" % (108 + k, 108, 148 + k, 148))
    w(";TYPE:Custom\nG1 Z%.2f F600\nM104 S0\nM140 S0\n" % (0.3 + n * lh + 10))
    return "".join(out).encode()

async def http_client(reader, writer):
    try:
        head = await reader.readuntil(b"\r\n\r\n")
        path = head.split(b" ")[1].decode()
        if path.startswith("/video") and not VIDEO_ON:
            writer.write(b"camera not ready")
        elif path.startswith("/video"):
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=--foo\r\n\r\n")
            while True:
                j = frame()
                writer.write(b"--foo\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n" % len(j) + j + b"\r\n")
                await writer.drain(); await asyncio.sleep(0.1)
        elif path.startswith("/thumb/"):
            body = thumb()
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
        elif path.startswith("/local/"):
            body = gcode_for(path)
            if body is None:
                writer.write(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
            else:
                writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n" % len(body))
                for i in range(0, len(body), 65536):
                    writer.write(body[i:i + 65536]); await writer.drain()
        elif path.startswith("/mesh"):
            body = mesh_json()
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
        else:
            writer.write(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
        await writer.drain()
    except (asyncio.IncompleteReadError, ConnectionError, IndexError):
        pass
    finally:
        writer.close()

async def main():
    servers = [await asyncio.start_server(ws_client, "127.0.0.1", WS_PORT),
               await asyncio.start_server(http_client, "127.0.0.1", VIDEO_PORT),
               await asyncio.start_server(http_client, "127.0.0.1", THUMB_PORT)]
    print(f"simulated printer ({A.scenario}, x{A.speed:g}): ws {WS_PORT}, video {VIDEO_PORT}, thumbs {THUMB_PORT}", flush=True)
    await asyncio.gather(*(s.serve_forever() for s in servers))

asyncio.run(main())
