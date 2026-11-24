#!/usr/bin/env python3
"""PrintDeck touchscreen mirror for a Centauri Carbon running COSMOS.

Serves the printer's own touchscreen (the 480x272 framebuffer the touchscreen app draws on) as PNG,
and feeds taps and drags back into its touch panel, so PrintDeck can show and drive the same screen.

  GET  /info                         {"width": 480, "height": 272}
  GET  /screen.png[?after=<etag>]    the screen; with `after`, waits up to 4 s for it to change
                                     (304 if it doesn't), so a client can simply ask again in a loop
  POST /touch?a=down|move|up&x=&y=   a touch, in screen pixels

No login, like Moonraker on port 80: anyone on the printer's network can see and press the screen.
Standard library only (COSMOS has python3 but no pip).
"""
import fcntl, json, struct, sys, threading, time, zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8091
FB, TOUCH = '/dev/fb0', '/dev/input/event0'


def fb_geometry():
    def read(name):
        with open('/sys/class/graphics/fb0/' + name) as f:
            return f.read().strip()
    w, h = (int(v) for v in read('virtual_size').split(','))
    return w, h, int(read('bits_per_pixel')), int(read('stride'))


W, H, BPP, STRIDE = fb_geometry()
if BPP != 32:
    sys.exit('printdeck-screen: only 32-bit framebuffers are handled (this one is %d-bit)' % BPP)


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)


class Screen:
    """The last frame read, PNG-encoded once per change."""
    def __init__(self):
        self.lock = threading.Lock()
        self.raw = b''
        self.tag = ''
        self.png = b''

    def grab(self):
        with open(FB, 'rb') as f:
            raw = f.read(STRIDE * H)
        tag = '%08x' % (zlib.crc32(raw) & 0xffffffff)
        with self.lock:
            if tag == self.tag:
                return tag, self.png
        rows = []
        for y in range(H):
            r = raw[y * STRIDE:y * STRIDE + W * 4]   # BGRA -> RGB
            out = bytearray(W * 3)
            out[0::3] = r[2::4]
            out[1::3] = r[1::4]
            out[2::3] = r[0::4]
            rows.append(b'\0' + bytes(out))
        png = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0))
               + chunk(b'IDAT', zlib.compress(b''.join(rows), 3)) + chunk(b'IEND', b''))
        with self.lock:
            self.tag, self.png = tag, png
        return tag, png


class Touch:
    """Writes input events into the touch panel's own device, as if the glass were pressed. The touchscreen
    app reads that device (it doesn't grab it), so it can't tell these from a finger."""
    EV_SYN, EV_KEY, EV_ABS, BTN_TOUCH = 0, 1, 3, 0x14a
    ABS_X, ABS_Y, SLOT, POS_X, POS_Y, TRACKING = 0x00, 0x01, 0x2f, 0x35, 0x36, 0x39

    def __init__(self):
        self.lock = threading.RLock()   # a lone "up" presses first, from inside act()
        self.track = 100
        self.down = False

    def send(self, events):
        now = time.time()
        sec, usec = int(now), int((now % 1) * 1e6)
        data = b''.join(struct.pack('llHHi', sec, usec, t, c, v) for t, c, v in events + [(self.EV_SYN, 0, 0)])
        with open(TOUCH, 'wb', buffering=0) as f:
            f.write(data)

    def act(self, action, x, y):
        x, y = max(0, min(W - 1, x)), max(0, min(H - 1, y))
        A = self.EV_ABS
        with self.lock:
            if action == 'down' or (action == 'move' and not self.down):
                self.track += 1
                self.down = True
                self.send([(A, self.SLOT, 0), (A, self.TRACKING, self.track), (A, self.POS_X, x), (A, self.POS_Y, y),
                           (self.EV_KEY, self.BTN_TOUCH, 1), (A, self.ABS_X, x), (A, self.ABS_Y, y)])
            elif action == 'move':
                self.send([(A, self.SLOT, 0), (A, self.POS_X, x), (A, self.POS_Y, y), (A, self.ABS_X, x), (A, self.ABS_Y, y)])
            elif action == 'up':
                if not self.down:   # a lone "up": press and lift, so it still lands as a tap
                    self.act('down', x, y)
                    time.sleep(0.05)
                self.down = False
                self.send([(A, self.SLOT, 0), (A, self.POS_X, x), (A, self.POS_Y, y), (A, self.TRACKING, -1),
                           (self.EV_KEY, self.BTN_TOUCH, 0)])
            else:
                raise ValueError(action)


SCREEN, TOUCHER = Screen(), Touch()


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def reply(self, code, body=b'', kind='application/json', extra=None):
        self.send_response(code)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Access-Control-Allow-Origin', '*')
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == '/info':
            return self.reply(200, json.dumps({'width': W, 'height': H}).encode())
        if u.path == '/screen.png':
            after = (q.get('after') or [''])[0]
            deadline = time.time() + 4
            tag, png = SCREEN.grab()
            while after and tag == after and time.time() < deadline:
                time.sleep(0.1)
                tag, png = SCREEN.grab()
            if after and tag == after:
                return self.reply(304, extra={'ETag': tag})
            return self.reply(200, png, 'image/png', {'ETag': tag})
        self.reply(404, b'{"error": "not found"}')

    def do_POST(self):
        u = urlparse(self.path)
        if u.path != '/touch':
            return self.reply(404, b'{"error": "not found"}')
        q = parse_qs(u.query)
        try:
            TOUCHER.act(q['a'][0], int(float(q['x'][0])), int(float(q['y'][0])))
        except (KeyError, ValueError) as e:
            return self.reply(400, json.dumps({'error': 'bad touch: %s' % e}).encode())
        n = int(self.headers.get('Content-Length') or 0)
        if n:
            self.rfile.read(n)
        self.reply(200, b'{"ok": true}')


if __name__ == '__main__':
    ThreadingHTTPServer.daemon_threads = True
    print('printdeck-screen: %dx%d screen on port %d' % (W, H, PORT), flush=True)
    ThreadingHTTPServer(('', PORT), Handler).serve_forever()
