#import "PDToolpath.h"
#import <CFNetwork/CFNetwork.h>
#import <UIKit/UIKit.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <libkern/OSAtomic.h>

NSString *const PDToolpathNotification = @"PDToolpathNotification";

#define PDTPMaxColors 8
static const uint32_t PDTPMagic = 0x50445450;  // "PDTP"
static const uint32_t PDTPVersion = 4;         // 2: the printer path after the header; 3: filament colour + a line type per segment;
                                                // 4: every filament's colour, and the tool (T<n>) per segment

#pragma mark - Parser (plain C, runs on a background queue)

typedef struct {
	int16_t *seg; uint8_t *typ; uint32_t nseg, capseg;
	uint8_t curType;                 // PDLineType of the current ;TYPE: block
	uint8_t curTool;                 // the last T<n> (multi-filament files: ElegooSlicer with the CANVAS)
	uint32_t colors[PDTPMaxColors]; int ncolors, sawColors;   // "; filament_colour = #RRGGBB;#RRGGBB;…"
	uint32_t *lstart; float *lz; uint32_t nlayer, caplayer;
	float minLen, minLen2;
	double x, y, z, e;
	int absXYZ, absE;
	int include, sawType, sawMarker;
	int allTypes;   // keep every feature (walls, infill, skin, support…), not just the visible surface
	int chain, pending;
	float kx, ky, kz, px, py;
	float bx0, by0, bx1, by1, bz1;
	char line[256]; int llen;
	uint32_t dropTick;
} PDParse;

static void pdp_init(PDParse *p) {
	memset(p, 0, sizeof(*p));
	p->capseg = 16384;
	p->seg = malloc(p->capseg * 6 * sizeof(int16_t));
	p->typ = malloc(p->capseg);
	p->caplayer = 256;
	p->lstart = malloc((p->caplayer + 1) * sizeof(uint32_t));
	p->lz = malloc(p->caplayer * sizeof(float));
	p->minLen = 0.4f; p->minLen2 = p->minLen * p->minLen;
	p->absXYZ = 1; p->absE = 1; p->include = 1;
	p->bx0 = p->by0 = 1e9f; p->bx1 = p->by1 = p->bz1 = -1e9f;
}

static void pdp_free(PDParse *p) { free(p->seg); free(p->typ); free(p->lstart); free(p->lz); p->seg = NULL; p->typ = NULL; p->lstart = NULL; p->lz = NULL; }

static inline int16_t pdp_q(float mm) {
	float v = mm * 100.0f;
	if (v > 32767) v = 32767; if (v < -32768) v = -32768;
	return (int16_t)lrintf(v);
}

// Merge each run of two joined segments of a layer into one; minLen doubles so new moves match.
static void pdp_decimate(PDParse *p) {
	uint32_t w = 0;
	for (uint32_t L = 0; L < p->nlayer; L++) {
		uint32_t a = p->lstart[L], b = (L + 1 < p->nlayer) ? p->lstart[L + 1] : p->nseg;
		p->lstart[L] = w;
		uint32_t i = a;
		while (i < b) {
			int16_t *s = p->seg + i * 6, *d = p->seg + w * 6;
			if (i + 1 < b) {
				int16_t *t = s + 6;
				if (s[3] == t[0] && s[4] == t[1] && s[5] == t[2] && p->typ[i] == p->typ[i + 1]) {
					int16_t m[6] = {s[0], s[1], s[2], t[3], t[4], t[5]};
					memcpy(d, m, sizeof m); p->typ[w] = p->typ[i]; w++; i += 2; continue;
				}
			}
			if (d != s) memmove(d, s, 6 * sizeof(int16_t));
			p->typ[w] = p->typ[i];
			w++; i++;
		}
	}
	p->nseg = w;
	p->minLen *= 2; p->minLen2 = p->minLen * p->minLen;
}

static void pdp_emit(PDParse *p, float x0, float y0, float x1, float y1, float z) {
	if (p->nlayer == 0) {  // extrusion before any layer marker: open layer 0
		p->lstart[0] = 0; p->lz[0] = z; p->nlayer = 1;
	}
	if (p->nseg >= PDToolpathMaxSegments) pdp_decimate(p);
	if (p->nseg >= 2 * PDToolpathMaxSegments) {  // pathological (no joined runs to merge): thin new ones out
		if ((p->dropTick++ & 1)) return;
	}
	if (p->nseg >= p->capseg) {
		p->capseg *= 2;
		p->seg = realloc(p->seg, p->capseg * 6 * sizeof(int16_t));
		p->typ = realloc(p->typ, p->capseg);
	}
	p->typ[p->nseg] = (uint8_t)(p->curType | (p->curTool << 4));
	int16_t *s = p->seg + p->nseg * 6;
	s[0] = pdp_q(x0); s[1] = pdp_q(y0); s[2] = pdp_q(z);
	s[3] = pdp_q(x1); s[4] = pdp_q(y1); s[5] = s[2];
	p->nseg++;
	if (x0 < p->bx0) p->bx0 = x0; if (x1 < p->bx0) p->bx0 = x1;
	if (y0 < p->by0) p->by0 = y0; if (y1 < p->by0) p->by0 = y1;
	if (x0 > p->bx1) p->bx1 = x0; if (x1 > p->bx1) p->bx1 = x1;
	if (y0 > p->by1) p->by1 = y0; if (y1 > p->by1) p->by1 = y1;
	if (z > p->bz1) p->bz1 = z;
}

static void pdp_flush(PDParse *p) {
	if (p->chain && p->pending) pdp_emit(p, p->kx, p->ky, p->px, p->py, p->kz);
	p->chain = 0; p->pending = 0;
}

static void pdp_newLayer(PDParse *p, float z) {
	pdp_flush(p);
	if (p->nlayer > 0 && p->lstart[p->nlayer - 1] == p->nseg) {  // previous layer stayed empty: reuse it
		p->lz[p->nlayer - 1] = z; return;
	}
	if (p->nlayer >= p->caplayer) {
		p->caplayer *= 2;
		p->lstart = realloc(p->lstart, (p->caplayer + 1) * sizeof(uint32_t));
		p->lz = realloc(p->lz, p->caplayer * sizeof(float));
	}
	p->lstart[p->nlayer] = p->nseg; p->lz[p->nlayer] = z; p->nlayer++;
}

static void pdp_extrude(PDParse *p, float ox, float oy, float nx, float ny, float z) {
	if (!p->sawMarker && (p->nlayer == 0 || z > p->lz[p->nlayer - 1] + 0.05f)) pdp_newLayer(p, z);
	if (!p->chain || p->kz != z) { pdp_flush(p); p->kx = ox; p->ky = oy; p->kz = z; p->chain = 1; }
	p->px = nx; p->py = ny; p->pending = 1;
	float dx = p->px - p->kx, dy = p->py - p->ky;
	if (dx * dx + dy * dy >= p->minLen2) {
		pdp_emit(p, p->kx, p->ky, p->px, p->py, p->kz);
		p->kx = p->px; p->ky = p->py; p->pending = 0;
	}
}

// G-code numbers: no exponents, so a small hand parser beats strtod on the A4.
static const char *pdp_num(const char *s, double *out) {
	int neg = 0; double v = 0, f = 0.1;
	if (*s == '-') { neg = 1; s++; } else if (*s == '+') s++;
	while (*s >= '0' && *s <= '9') { v = v * 10 + (*s - '0'); s++; }
	if (*s == '.') { s++; while (*s >= '0' && *s <= '9') { v += (*s - '0') * f; f *= 0.1; s++; } }
	*out = neg ? -v : v;
	return s;
}

static int pdp_ieq_prefix(const char *s, const char *pre) {
	while (*pre) { if (*s != *pre) return 0; s++; pre++; }
	return 1;
}

static int pdp_contains_ci(const char *s, const char *needle) {
	size_t n = strlen(needle);
	for (; *s; s++) {
		size_t i = 0;
		while (i < n && s[i] && ((s[i] | 0x20) == needle[i])) i++;
		if (i == n) return 1;
	}
	return 0;
}

// ;TYPE: names from CuraEngine (WALL-OUTER, FILL, SKIN…) and ElegooSlicer/Orca ("Outer wall", "Sparse infill"…).
static uint8_t pdp_lineType(const char *t) {
	if (pdp_contains_ci(t, "support")) return pdp_contains_ci(t, "interface") ? PDLineSupportInterface : PDLineSupport;
	if (pdp_contains_ci(t, "skirt") || pdp_contains_ci(t, "brim") || pdp_contains_ci(t, "raft")) return PDLineSkirt;
	if (pdp_contains_ci(t, "bridge")) return PDLineBridge;
	if (pdp_contains_ci(t, "overhang")) return PDLineOverhang;
	if (pdp_contains_ci(t, "outer")) return PDLineOuterWall;
	if (pdp_contains_ci(t, "inner") || pdp_contains_ci(t, "wall") || pdp_contains_ci(t, "perimeter")) return PDLineInnerWall;
	if (pdp_contains_ci(t, "top")) return PDLineTopSurface;
	if (pdp_contains_ci(t, "bottom") || pdp_contains_ci(t, "solid") || pdp_contains_ci(t, "skin")) return PDLineSolidInfill;
	if (pdp_contains_ci(t, "gap")) return PDLineGapFill;
	if (pdp_contains_ci(t, "fill")) return PDLineSparseInfill;
	return PDLineOther;
}

static void pdp_comment(PDParse *p, const char *c) {
	if (pdp_ieq_prefix(c, "LAYER_CHANGE")) {
		p->sawMarker = 1;
		pdp_newLayer(p, (float)p->z);
	} else if (c[0] == 'Z' && c[1] == ':') {
		double v; pdp_num(c + 2, &v);
		if (p->sawMarker && p->nlayer) p->lz[p->nlayer - 1] = (float)v;
	} else if (pdp_ieq_prefix(c, "TYPE:")) {
		const char *t = c + 5;
		p->sawType = 1;
		int inc = p->allTypes ? !pdp_contains_ci(t, "custom")
			: pdp_contains_ci(t, "outer") || pdp_contains_ci(t, "overhang") || pdp_contains_ci(t, "skirt") || pdp_contains_ci(t, "brim");
		uint8_t ty = pdp_lineType(t);
		if (inc != p->include || ty != p->curType) pdp_flush(p);
		p->include = inc;
		p->curType = ty;
	} else if (!p->sawColors && pdp_ieq_prefix(c, "filament_colour") && (c[15] == ' ' || c[15] == '=' || c[15] == ':')) {
		// One "#RRGGBB" per filament, separated by ';' (Orca also quotes or brackets them).
		p->sawColors = 1;
		for (const char *h = c + 15; *h && p->ncolors < PDTPMaxColors; ) {
			if (*h != '#') { h++; continue; }
			uint32_t v = 0; int k = 0;
			for (h++; k < 6; k++, h++) {
				char ch = *h; int d = ch >= '0' && ch <= '9' ? ch - '0' : (ch | 0x20) >= 'a' && (ch | 0x20) <= 'f' ? (ch | 0x20) - 'a' + 10 : -1;
				if (d < 0) break;
				v = v * 16 + (uint32_t)d;
			}
			if (k == 6) p->colors[p->ncolors++] = v;
		}
	}
}

static void pdp_move(PDParse *p, int code, const char *s) {
	double X = NAN, Y = NAN, Z = NAN, E = NAN, I = 0, J = 0, v;
	for (;;) {
		while (*s == ' ' || *s == '\t') s++;
		char w = *s;
		if (!w || w == ';') break;
		s++;
		if ((w >= 'A' && w <= 'Z') || (w >= 'a' && w <= 'z')) {
			const char *n = pdp_num(s, &v);
			if (n == s) continue;
			s = n;
			switch (w & ~0x20) {
				case 'X': X = v; break; case 'Y': Y = v; break; case 'Z': Z = v; break;
				case 'E': E = v; break; case 'I': I = v; break; case 'J': J = v; break;
			}
		}
	}
	double ox = p->x, oy = p->y, oz = p->z;
	double nx = isnan(X) ? ox : (p->absXYZ ? X : ox + X);
	double ny = isnan(Y) ? oy : (p->absXYZ ? Y : oy + Y);
	double nz = isnan(Z) ? oz : (p->absXYZ ? Z : oz + Z);
	int extruding = 0;
	if (!isnan(E)) {
		int absE = p->absE && p->absXYZ;  // Klipper: E is relative under G91 or M83
		double de = absE ? E - p->e : E;
		p->e = absE ? E : p->e + E;
		extruding = de > 1e-6;
	}
	p->x = nx; p->y = ny; p->z = nz;
	int moved = (nx != ox || ny != oy);
	if (nz != oz && !moved) { pdp_flush(p); return; }
	if (!moved) return;
	if (!extruding || !p->include) { pdp_flush(p); return; }
	if (code == 2 || code == 3) {
		double cx = ox + I, cy = oy + J, r = hypot(ox - cx, oy - cy);
		double a0 = atan2(oy - cy, ox - cx), a1 = atan2(ny - cy, nx - cx), d = a1 - a0;
		if (code == 2 && d >= 0) d -= 2 * M_PI;
		if (code == 3 && d <= 0) d += 2 * M_PI;
		int n = (int)ceil(fabs(d) * r / 1.0);
		if (n < 1) n = 1; if (n > 32) n = 32;
		float lx = (float)ox, ly = (float)oy;
		for (int k = 1; k <= n; k++) {
			double a = a0 + d * k / n;
			float qx = (k == n) ? (float)nx : (float)(cx + r * cos(a)), qy = (k == n) ? (float)ny : (float)(cy + r * sin(a));
			pdp_extrude(p, lx, ly, qx, qy, (float)nz);
			lx = qx; ly = qy;
		}
	} else {
		pdp_extrude(p, (float)ox, (float)oy, (float)nx, (float)ny, (float)nz);
	}
}

static void pdp_line(PDParse *p, char *l) {
	while (*l == ' ' || *l == '\t') l++;
	if (*l == ';') { l++; while (*l == ' ') l++; pdp_comment(p, l); return; }
	char c = *l & ~0x20;
	if (c == 'T' && l[1] >= '0' && l[1] <= '9') {   // tool change: the next extrusions use filament n
		int n = atoi(l + 1);
		if (n < 16 && n != p->curTool) { pdp_flush(p); p->curTool = (uint8_t)n; }
		return;
	}
	if (c != 'G' && c != 'M') return;
	double v; const char *s = pdp_num(l + 1, &v);
	int code = (int)v;
	if (c == 'G') {
		if (code >= 0 && code <= 3 && (*s == ' ' || *s == '\t' || *s == 0 || *s == ';')) pdp_move(p, code, s);
		else if (code == 90) p->absXYZ = 1;   // Klipper keeps the M82/M83 extrude mode across G90/G91
		else if (code == 91) p->absXYZ = 0;
		else if (code == 92) {
			double w;
			for (;;) {
				while (*s == ' ') s++;
				char k = *s & ~0x20;
				if (!*s || *s == ';') break;
				s++;
				const char *n = pdp_num(s, &w); if (n == s) continue; s = n;
				if (k == 'E') p->e = w; else if (k == 'X') p->x = w; else if (k == 'Y') p->y = w; else if (k == 'Z') p->z = w;
			}
		}
	} else {
		if (code == 82) p->absE = 1;
		else if (code == 83) p->absE = 0;
	}
}

static void pdp_feed(PDParse *p, const uint8_t *b, size_t n) {
	for (size_t i = 0; i < n; i++) {
		char ch = (char)b[i];
		if (ch == '\n') { p->line[p->llen] = 0; pdp_line(p, p->line); p->llen = 0; }
		else if (ch != '\r' && p->llen < (int)sizeof(p->line) - 1) p->line[p->llen++] = ch;
	}
}

static void pdp_finish(PDParse *p) {
	if (p->llen) { p->line[p->llen] = 0; pdp_line(p, p->line); p->llen = 0; }
	pdp_flush(p);
	// Drop trailing empty layers (end G-code after the last marker).
	while (p->nlayer > 0 && p->lstart[p->nlayer - 1] == p->nseg) p->nlayer--;
	p->lstart[p->nlayer] = p->nseg;
}

#pragma mark - PDToolpath

@interface PDToolpath () {
@public
	int16_t *_seg; uint8_t *_typ; uint32_t *_lstart; float *_lz;
	uint32_t _colors[PDTPMaxColors]; uint32_t _ncolors;
	NSUInteger _nseg, _nlayer;
	float _b[5];
	float _minLen;
	long long _bytes;
	NSString *_path;
}
@end

@implementation PDToolpath
- (NSString *)path { return _path; }
- (NSUInteger)segmentCount { return _nseg; }
- (NSUInteger)layerCount { return _nlayer; }
- (const int16_t *)segments { return _seg; }
- (const uint32_t *)layerStart { return _lstart; }
- (const float *)layerZ { return _lz; }
- (float)minX { return _b[0]; }
- (float)minY { return _b[1]; }
- (float)maxX { return _b[2]; }
- (float)maxY { return _b[3]; }
- (float)maxZ { return _b[4]; }
- (float)minLen { return _minLen; }
- (const uint8_t *)lineTypes { return _typ; }
- (BOOL)hasFilamentColor { return _ncolors > 0; }
- (uint32_t)filamentColor { return _ncolors ? _colors[0] : 0; }
- (NSUInteger)filamentColorCount { return _ncolors; }
- (const uint32_t *)filamentColors { return _colors; }
- (long long)fileBytes { return _bytes; }
- (void)dealloc { free(_seg); free(_typ); free(_lstart); free(_lz); }

+ (PDToolpath *)fromParse:(PDParse *)p path:(NSString *)path bytes:(long long)bytes {
	PDToolpath *t = [[PDToolpath alloc] init];
	t->_path = [path copy];
	t->_nseg = p->nseg; t->_nlayer = p->nlayer;
	t->_seg = p->seg ? realloc(p->seg, MAX(1u, p->nseg) * 6 * sizeof(int16_t)) : NULL; // shrink to fit
	t->_typ = p->typ ? realloc(p->typ, MAX(1u, p->nseg)) : NULL;
	t->_lstart = p->lstart; t->_lz = p->lz;
	memcpy(t->_colors, p->colors, sizeof t->_colors); t->_ncolors = (uint32_t)p->ncolors;
	p->seg = NULL; p->typ = NULL; p->lstart = NULL; p->lz = NULL;
	t->_b[0] = p->bx0; t->_b[1] = p->by0; t->_b[2] = p->bx1; t->_b[3] = p->by1; t->_b[4] = p->bz1;
	if (!p->nseg) { t->_b[0] = t->_b[1] = 0; t->_b[2] = t->_b[3] = 256; t->_b[4] = 1; }
	t->_minLen = p->minLen;
	t->_bytes = bytes;
	return t;
}

// A local G-code file (e.g. one PrintDeck just sliced), parsed synchronously: call it off the main thread.
+ (PDToolpath *)toolpathFromFile:(NSString *)file path:(NSString *)path allTypes:(BOOL)all {
	FILE *f = fopen([file fileSystemRepresentation], "rb");
	if (!f) return nil;
	PDParse p;
	pdp_init(&p);
	p.allTypes = all;
	uint8_t buf[65536];
	size_t n;
	long long bytes = 0;
	while ((n = fread(buf, 1, sizeof buf, f)) > 0) { pdp_feed(&p, buf, n); bytes += (long long)n; }
	fclose(f);
	pdp_finish(&p);
	PDToolpath *t = [self fromParse:&p path:path bytes:bytes];
	pdp_free(&p);
	return t;
}

- (NSData *)archive {
	NSMutableData *d = [NSMutableData data];
	uint32_t h[4] = {PDTPMagic, PDTPVersion, (uint32_t)_nlayer, (uint32_t)_nseg};
	[d appendBytes:h length:sizeof h];
	NSData *p = [_path dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
	uint32_t pl = (uint32_t)[p length];
	[d appendBytes:&pl length:4];
	[d appendData:p];
	[d appendBytes:&_bytes length:sizeof _bytes];
	[d appendBytes:_b length:sizeof _b];
	[d appendBytes:&_minLen length:sizeof _minLen];
	[d appendBytes:&_ncolors length:4];
	[d appendBytes:_colors length:sizeof _colors];
	[d appendBytes:_lz length:_nlayer * sizeof(float)];
	[d appendBytes:_lstart length:(_nlayer + 1) * sizeof(uint32_t)];
	[d appendBytes:_seg length:_nseg * 6 * sizeof(int16_t)];
	[d appendBytes:_typ length:_nseg];
	return d;
}

+ (PDToolpath *)unarchive:(NSData *)d {
	const uint8_t *b = [d bytes]; NSUInteger n = [d length], off = 0;
	uint32_t h[4], pl;
	if (n < sizeof h + 4) return nil;
	memcpy(h, b, sizeof h); off += sizeof h;
	if (h[0] != PDTPMagic || h[1] != PDTPVersion) return nil;
	memcpy(&pl, b + off, 4); off += 4;
	if (pl > 4096 || n < off + pl) return nil;
	NSString *path = [[NSString alloc] initWithBytes:b + off length:pl encoding:NSUTF8StringEncoding];
	off += pl;
	NSUInteger nl = h[2], ns = h[3];
	NSUInteger need = off + 8 + 20 + 4 + 4 + 4 * PDTPMaxColors + nl * 4 + (nl + 1) * 4 + ns * 13;
	if (n != need || ![path length]) return nil;
	PDToolpath *t = [[PDToolpath alloc] init];
	t->_path = path;
	memcpy(&t->_bytes, b + off, 8); off += 8;
	memcpy(t->_b, b + off, 20); off += 20;
	memcpy(&t->_minLen, b + off, 4); off += 4;
	memcpy(&t->_ncolors, b + off, 4); off += 4;
	memcpy(t->_colors, b + off, sizeof t->_colors); off += sizeof t->_colors;
	if (t->_ncolors > PDTPMaxColors) return nil;
	t->_nlayer = nl; t->_nseg = ns;
	t->_lz = malloc(MAX(1u, nl) * 4); memcpy(t->_lz, b + off, nl * 4); off += nl * 4;
	t->_lstart = malloc((nl + 1) * 4); memcpy(t->_lstart, b + off, (nl + 1) * 4); off += (nl + 1) * 4;
	t->_seg = malloc(MAX(1u, ns) * 12); memcpy(t->_seg, b + off, ns * 12); off += ns * 12;
	t->_typ = malloc(MAX(1u, ns)); memcpy(t->_typ, b + off, ns);
	return t;
}
@end

#pragma mark - Loader

@interface PDToolpathLoader () {
	volatile int32_t _gen;
}
@property (nonatomic, readwrite, strong) PDToolpath *toolpath;
@property (nonatomic, readwrite, copy) NSString *loadingPath, *error, *requestedPath;
@property (nonatomic, readwrite) double progress;
@property (nonatomic, strong) NSURL *requestedURL;
@property (nonatomic, assign) long long requestedSize;
@property (nonatomic, assign) dispatch_queue_t queue;  // not an object under a 5.0 deployment target
@property (nonatomic, readwrite, copy) NSString *slot;
@property (nonatomic, strong) PDToolpathLoader *waitingOn;   // another slot already fetching the same file
@end

@implementation PDToolpathLoader

static NSString *PDTPCacheDir(void);

static NSArray *PDTPSlots(void) { return [NSArray arrayWithObjects:@"job", @"files", nil]; }

+ (PDToolpathLoader *)loaderForSlot:(NSString *)slot {
	static NSMutableDictionary *loaders;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		loaders = [NSMutableDictionary dictionary];
		for (NSString *s in PDTPSlots()) {
			PDToolpathLoader *l = [[PDToolpathLoader alloc] init];
			l.slot = s;
			l.queue = dispatch_queue_create([[@"printdeck.toolpath." stringByAppendingString:s] UTF8String], DISPATCH_QUEUE_SERIAL);
			[loaders setObject:l forKey:s];
		}
		// Anything in the cache folder that isn't a slot file (older per-file caches) goes.
		NSFileManager *fm = [NSFileManager defaultManager];
		NSString *dir = PDTPCacheDir();
		for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:NULL])
			if (![PDTPSlots() containsObject:[f stringByDeletingPathExtension]] || ![[f pathExtension] isEqualToString:@"tp"])
				[fm removeItemAtPath:[dir stringByAppendingPathComponent:f] error:NULL];
	});
	return [loaders objectForKey:slot] ?: [loaders objectForKey:@"job"];
}

+ (PDToolpathLoader *)shared { return [self loaderForSlot:@"job"]; }

- (void)post { [[NSNotificationCenter defaultCenter] postNotificationName:PDToolpathNotification object:self]; }

static NSString *const PDTPBusy = @"The printer won't send files while it's printing or getting a print ready (it answers “device busy”). "
	@"The preview loads as soon as it will; PrintDeck keeps asking. (Files opened in PrintDeck's file list before printing show right away.)";

static NSString *PDTPCacheDir(void) {
	NSString *d = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"toolpaths"];
	[[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
	return d;
}

static NSString *PDTPSlotFile(NSString *slot) {
	return [PDTPCacheDir() stringByAppendingPathComponent:[slot stringByAppendingPathExtension:@"tp"]];
}

// A cached toolpath for `path` in any slot (the job and the Files card often show the same file), or nil.
static PDToolpath *PDTPCached(NSString *path, long long size, NSString *preferSlot) {
	NSMutableArray *order = [NSMutableArray arrayWithObject:preferSlot];
	for (NSString *s in PDTPSlots()) if (![s isEqualToString:preferSlot]) [order addObject:s];
	for (NSString *s in order) {
		NSData *d = [NSData dataWithContentsOfFile:PDTPSlotFile(s) options:NSDataReadingMappedIfSafe error:NULL];
		PDToolpath *t = d ? [PDToolpath unarchive:d] : nil;
		if (t && [t.path isEqualToString:path] && (size <= 0 || t.fileBytes == size)) return t;
	}
	return nil;
}

- (void)loadPath:(NSString *)path url:(NSURL *)url size:(long long)size {
	if (![path length] || !url) return;
	self.requestedPath = path;
	if ([path isEqualToString:self.toolpath.path] && (size <= 0 || size == self.toolpath.fileBytes)) {
		if (self.error) { self.error = nil; }
		[self post];
		return;
	}
	if ([path isEqualToString:self.loadingPath]) return;
	[self stopWaiting];
	self.requestedURL = url; self.requestedSize = size;
	// The other slot has this file in memory (share it: no second copy, no download) or is fetching it (wait).
	for (NSString *s in PDTPSlots()) {
		PDToolpathLoader *o = [PDToolpathLoader loaderForSlot:s];
		if (o == self) continue;
		if ([o.toolpath.path isEqualToString:path] && (size <= 0 || size == o.toolpath.fileBytes) && ![o.loadingPath length]) {
			[self adopt:o.toolpath];
			return;
		}
		if ([o.loadingPath isEqualToString:path]) {
			OSAtomicIncrement32Barrier(&_gen);   // cancel anything of ours in flight
			self.waitingOn = o;
			self.loadingPath = path; self.error = nil; self.progress = o.progress;
			[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(otherChanged) name:PDToolpathNotification object:o];
			[self post];
			return;
		}
	}
	[self startLoad:path url:url size:size useCache:YES];
}

- (void)stopWaiting {
	if (!self.waitingOn) return;
	[[NSNotificationCenter defaultCenter] removeObserver:self name:PDToolpathNotification object:self.waitingOn];
	self.waitingOn = nil;
}

- (void)otherChanged {
	PDToolpathLoader *o = self.waitingOn;
	NSString *path = self.loadingPath;
	if (!o || !path) return;
	if ([o.loadingPath isEqualToString:path]) { self.progress = o.progress; [self post]; return; }
	[self stopWaiting];
	self.loadingPath = nil;
	if ([o.toolpath.path isEqualToString:path]) [self adopt:o.toolpath];
	else [self startLoad:path url:self.requestedURL size:self.requestedSize useCache:YES];  // it failed or moved on
}

// Take a toolpath another slot already has, and keep it as this slot's cached file too.
- (void)adopt:(PDToolpath *)t {
	OSAtomicIncrement32Barrier(&_gen);
	self.loadingPath = nil; self.error = nil;
	self.toolpath = t;
	NSString *file = PDTPSlotFile(self.slot);
	dispatch_async(self.queue, ^{ [[t archive] writeToFile:file atomically:YES]; });
	[self post];
}

- (void)reload {
	if (!self.requestedPath || !self.requestedURL) return;
	[[NSFileManager defaultManager] removeItemAtPath:PDTPSlotFile(self.slot) error:NULL];
	[self startLoad:self.requestedPath url:self.requestedURL size:self.requestedSize useCache:NO];
}

- (void)startLoad:(NSString *)path url:(NSURL *)url size:(long long)size useCache:(BOOL)useCache {
	[self startLoad:path url:url size:size useCache:useCache busyTries:0];
}

- (void)startLoad:(NSString *)path url:(NSURL *)url size:(long long)size useCache:(BOOL)useCache busyTries:(int)tries {
	[self stopWaiting];
	int32_t gen = OSAtomicIncrement32Barrier(&_gen);
	self.requestedURL = url; self.requestedSize = size;
	self.loadingPath = path; self.error = nil; self.progress = 0;
	[self post];
	__weak PDToolpathLoader *weakSelf = self;
	dispatch_async(self.queue, ^{
		PDToolpathLoader *me = weakSelf;
		if (!me || me->_gen != gen) return;
		// Each slot keeps one file on disk: the one it shows now. Writing it replaces (deletes) the previous one.
		NSString *cacheFile = PDTPSlotFile(me.slot);
		PDToolpath *t = nil;
		NSString *err = nil;
		if (useCache) {
			t = PDTPCached(path, size, me.slot);
			if (t && ![[PDToolpath unarchive:[NSData dataWithContentsOfFile:cacheFile options:NSDataReadingMappedIfSafe error:NULL]].path isEqualToString:path])
				[[t archive] writeToFile:cacheFile atomically:YES];   // found in the other slot: keep a copy in ours
		}
		if (!t) {
			CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
			t = [me fetch:url path:path expected:size gen:gen error:&err];
			NSString *line = [NSString stringWithFormat:@"toolpath %@: %.1f MB -> %u layers, %u segments (min %.1f mm) in %.1f s%@%@\n", [path lastPathComponent],
				t.fileBytes / 1048576.0, (unsigned)t.layerCount, (unsigned)t.segmentCount, t.minLen, CFAbsoluteTimeGetCurrent() - t0, err ? @" error: " : @"", err ?: @""];
			NSLog(@"PrintDeck: %@", line);
			// Also to /tmp (readable over SSH; iOS 5 has no handy syslog reader) — a developer aid, truncated at 64 KB.
			NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/printdeck-toolpath.log"];
			if (!fh || [fh seekToEndOfFile] > 65536) { [line writeToFile:@"/tmp/printdeck-toolpath.log" atomically:NO encoding:NSUTF8StringEncoding error:NULL]; }
			else { [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
			if (t && t.segmentCount) [[t archive] writeToFile:cacheFile atomically:YES];
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			if (me->_gen != gen) return;
			me.loadingPath = nil;
			if (t && t.segmentCount) me.toolpath = t;
			else if (t) me.error = @"No printable moves found in this file.";
			else me.error = err ?: @"Couldn't load the file.";
			[me post];
			// The printer was busy: ask again every 20 s (for up to a day's printing), unless something else has been
			// asked for meanwhile.
			if (err == PDTPBusy && tries < 4320) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
				if (me->_gen == gen && !me.loadingPath && [me.requestedPath isEqualToString:path])
					[me startLoad:path url:url size:size useCache:NO busyTries:tries + 1];
			});
		});
	});
}

// Streams the file (CFHTTP read stream, polled so a stall times out and a newer request cancels it) through the parser.
- (PDToolpath *)fetch:(NSURL *)url path:(NSString *)path expected:(long long)expected gen:(int32_t)gen error:(NSString **)err {
	CFHTTPMessageRef req = CFHTTPMessageCreateRequest(NULL, CFSTR("GET"), (__bridge CFURLRef)url, kCFHTTPVersion1_1);
	CFReadStreamRef rs = CFReadStreamCreateForHTTPRequest(NULL, req);
	CFRelease(req);
	CFReadStreamSetProperty(rs, kCFStreamPropertyHTTPShouldAutoredirect, kCFBooleanTrue);
	if (!CFReadStreamOpen(rs)) { CFRelease(rs); *err = @"Couldn't reach the printer."; return nil; }
	PDParse *p = malloc(sizeof(PDParse));
	pdp_init(p);
	size_t bufLen = 32768;
	uint8_t *buf = malloc(bufLen);
	long long got = 0, total = expected;
	BOOL headerChecked = NO, ok = YES;
	CFAbsoluteTime lastData = CFAbsoluteTimeGetCurrent(), lastPost = 0;
	for (;;) {
		if (_gen != gen) { ok = NO; *err = @"cancelled"; break; }
		CFStreamStatus st = CFReadStreamGetStatus(rs);
		if (st == kCFStreamStatusError) { ok = NO; *err = @"The download failed."; break; }
		if (st == kCFStreamStatusAtEnd) break;
		if (!CFReadStreamHasBytesAvailable(rs)) {
			if (CFAbsoluteTimeGetCurrent() - lastData > 15) { ok = NO; *err = @"The printer stopped sending the file."; break; }
			usleep(3000);   // short: with the camera sharing the Wi-Fi, data comes in small bursts
			continue;
		}
		CFIndex n = CFReadStreamRead(rs, buf, bufLen);
		if (n < 0) { ok = NO; *err = @"The download failed."; break; }
		if (n == 0) break;
		if (!headerChecked) {
			headerChecked = YES;
			CFHTTPMessageRef resp = (CFHTTPMessageRef)CFReadStreamCopyProperty(rs, kCFStreamPropertyHTTPResponseHeader);
			if (resp) {
				CFIndex code = CFHTTPMessageGetResponseStatusCode(resp);
				NSString *len = (__bridge_transfer NSString *)CFHTTPMessageCopyHeaderFieldValue(resp, CFSTR("Content-Length"));
				CFRelease(resp);
				if (code == 404) { ok = NO; *err = @"The file is no longer on the printer."; break; }
				// The Centauri's web server sends no files while a job is underway (levelling, heating, printing):
				// HTTP 500 with the body "device busy". Not a failure: startLoad keeps trying.
				if (code == 500 || code == 503) {
					NSString *body = [[NSString alloc] initWithBytes:buf length:(NSUInteger)MIN(n, 64) encoding:NSUTF8StringEncoding];
					if (body && [[body lowercaseString] rangeOfString:@"busy"].location != NSNotFound) { ok = NO; *err = PDTPBusy; break; }
				}
				if (code != 200) { ok = NO; *err = [NSString stringWithFormat:@"The printer answered HTTP %d.", (int)code]; break; }
				if ([len longLongValue] > 0) total = [len longLongValue];
			}
		}
		lastData = CFAbsoluteTimeGetCurrent();
		got += n;
		pdp_feed(p, buf, (size_t)n);
		if (total > 0 && lastData - lastPost > 0.3) {
			lastPost = lastData;
			double prog = MIN(1.0, (double)got / (double)total);
			dispatch_async(dispatch_get_main_queue(), ^{
				if (self->_gen == gen) { self.progress = prog; [self post]; }
			});
		}
	}
	CFReadStreamClose(rs);
	CFRelease(rs);
	free(buf);
	PDToolpath *t = nil;
	if (ok && got > 0) {
		pdp_finish(p);
		t = [PDToolpath fromParse:p path:path bytes:got];
	} else if (ok) *err = @"The file was empty.";
	pdp_free(p);
	free(p);
	return t;
}

@end
