# Read-only SDCP probe: attributes (1), file list (258), history ids (320), then details (321) for the newest task.
import socket, os, base64, json, struct, time, uuid, sys
HOST = sys.argv[1]
s = socket.create_connection((HOST, 3030), timeout=5)
s.sendall(f"GET /websocket HTTP/1.1\r\nHost: {HOST}:3030\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {base64.b64encode(os.urandom(16)).decode()}\r\nSec-WebSocket-Version: 13\r\n\r\n".encode())
buf = b""
while b"\r\n\r\n" not in buf: buf += s.recv(4096)
buf = buf.split(b"\r\n\r\n", 1)[1]
def send(cmd, data={}):
    p = json.dumps({"Id": "", "Data": {"Cmd": cmd, "Data": data, "RequestID": uuid.uuid4().hex, "MainboardID": "", "TimeStamp": int(time.time()*1000), "From": 1}}).encode()
    m = os.urandom(4)
    h = bytes([0x81]) + (bytes([0x80|len(p)]) if len(p) < 126 else bytes([0x80|126]) + struct.pack(">H", len(p)))
    s.sendall(h + m + bytes(b ^ m[i % 4] for i, b in enumerate(p)))
def recv():
    global buf
    def need(n):
        global buf
        while len(buf) < n: buf += s.recv(65536)
    need(2); n = buf[1] & 0x7f; off = 2
    if n == 126: need(4); n = struct.unpack(">H", buf[2:4])[0]; off = 4
    elif n == 127: need(10); n = struct.unpack(">Q", buf[2:10])[0]; off = 10
    need(off + n); op = buf[0] & 0x0f; data = buf[off:off+n]; buf = buf[off+n:]
    return op, data
send(1); send(258, {"Url": "/local"}); send(320); send(134)
s.settimeout(1)
end = time.time() + 5; asked = False
while time.time() < end:
    try: op, data = recv()
    except socket.timeout: continue
    if op != 1: continue
    m = json.loads(data)
    t = m.get("Topic", "")
    if "/status/" in t: continue
    d = m.get("Data", {})
    print(t, "Cmd", d.get("Cmd"), json.dumps(m.get("Attributes") or d.get("Data"))[:1800]); print("---")
    if d.get("Cmd") == 320 and not asked:
        ids = (d.get("Data") or {}).get("HistoryData") or []
        if ids: send(321, {"Id": ids[:1]}); asked = True; end = time.time() + 3
s.close()
