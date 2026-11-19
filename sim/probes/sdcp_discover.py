import socket, json, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.settimeout(1.0)
for addr in ("255.255.255.255", "192.168.0.255"):
    try: s.sendto(b"M99999", (addr, 3000))
    except Exception as e: print("send", addr, e)
end = time.time() + 4
while time.time() < end:
    try:
        data, src = s.recvfrom(65535)
    except socket.timeout:
        continue
    try:
        d = json.loads(data)
        dd = d.get("Data", d)
        print(src[0], json.dumps({k: dd.get(k) for k in ("Name","MachineName","MainboardIP","ProtocolVersion","FirmwareVersion")}))
    except Exception:
        print(src[0], data[:200])
print("done")
