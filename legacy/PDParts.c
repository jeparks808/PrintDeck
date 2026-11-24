#include "PDParts.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

// ISO 4032 nuts, ISO 4017 hex heads, ISO 4762 socket caps, ISO 10642 countersunk heads (nominal sizes).
static const PDMetric PDMetrics[] = {
	{"M2", 2, 0.4f, 4, 1.6f, 1.4f, 3.8f, 2, 1.5f, 4},
	{"M2.5", 2.5f, 0.45f, 5, 2, 1.7f, 4.5f, 2.5f, 2, 5},
	{"M3", 3, 0.5f, 5.5f, 2.4f, 2, 5.5f, 3, 2.5f, 6},
	{"M4", 4, 0.7f, 7, 3.2f, 2.8f, 7, 4, 3, 8},
	{"M5", 5, 0.8f, 8, 4.7f, 3.5f, 8.5f, 5, 4, 10},
	{"M6", 6, 1, 10, 5.2f, 4, 10, 6, 5, 12},
	{"M8", 8, 1.25f, 13, 6.8f, 5.3f, 13, 8, 6, 16},
	{"M10", 10, 1.5f, 16, 8.4f, 6.4f, 16, 10, 8, 20},
	{"M12", 12, 1.75f, 18, 10.8f, 7.5f, 18, 12, 10, 24},
};
int PDMetricCount(void) { return (int)(sizeof PDMetrics / sizeof PDMetrics[0]); }
const PDMetric *PDMetricSize(int i) { return i >= 0 && i < PDMetricCount() ? &PDMetrics[i] : NULL; }

#pragma mark - Output

typedef struct { float *t; int n, cap, oom; } Out;

static int same(const double *a, const double *b) { return a[0] == b[0] && a[1] == b[1] && a[2] == b[2]; }

// One triangle (counter-clockwise from outside). Triangles with two equal corners (at a pole) are left out.
static void tri3(Out *o, const double *a, const double *b, const double *c) {
	if (o->oom || same(a, b) || same(b, c) || same(a, c)) return;
	if (o->n == o->cap) {
		int cap = o->cap ? o->cap * 2 : 256;
		float *t = realloc(o->t, (size_t)cap * 9 * sizeof(float));
		if (!t) { o->oom = 1; return; }
		o->t = t; o->cap = cap;
	}
	float *t = o->t + (size_t)o->n++ * 9;
	for (int k = 0; k < 3; k++) { t[k] = (float)a[k]; t[3 + k] = (float)b[k]; t[6 + k] = (float)c[k]; }
}
static void quad3(Out *o, const double *a, const double *b, const double *c, const double *d) { tri3(o, a, b, c); tri3(o, a, c, d); }

static int finish(Out *o, PDCSGMesh *out) {
	if (o->oom || !o->n) { free(o->t); out->tris = NULL; out->count = 0; return -1; }
	out->tris = o->t; out->count = o->n;
	return 0;
}

// Points round a circle land exactly on the same doubles every time they are asked for.
static void ring(double r, int i, int sides, double phase, double z, double *p) {
	if (r == 0) { p[0] = 0; p[1] = 0; p[2] = z; return; }
	double a = 2 * M_PI * (i % sides) / sides + phase;
	p[0] = r * cos(a); p[1] = r * sin(a); p[2] = z;
}

// A solid of revolution about z. The profile (radius, z) runs from the axis at the bottom, out and up, back to
// the axis at the top, so it closes itself.
static void lathe(Out *o, const double (*pr)[2], int np, int sides, double phase) {
	for (int i = 0; i < sides; i++)
		for (int k = 0; k + 1 < np; k++) {
			double a[3], b[3], c[3], d[3];
			ring(pr[k][0], i, sides, phase, pr[k][1], a);
			ring(pr[k][0], i + 1, sides, phase, pr[k][1], b);
			ring(pr[k + 1][0], i + 1, sides, phase, pr[k + 1][1], c);
			ring(pr[k + 1][0], i, sides, phase, pr[k + 1][1], d);
			quad3(o, a, b, c, d);
		}
}

static int sidesFor(double r) { int s = (int)ceil(2 * M_PI * r / 0.6); s = s < 32 ? 32 : s > 96 ? 96 : s; return (s + 3) / 4 * 4; }

#pragma mark - Threads

// ISO profile over one pitch, from the root: root flat p/4, flank 5p/16 up, crest flat p/8, flank 5p/16 down.
static const double PDThreadCorners[4] = {0, 0.25, 0.5625, 0.6875};
static double threadRadius(double u, double rmin, double rmaj) {   // u in [0, 1)
	if (u < 0.25) return rmin;
	if (u < 0.5625) return rmin + (rmaj - rmin) * (u - 0.25) / 0.3125;
	if (u < 0.6875) return rmaj;
	return rmaj - (rmaj - rmin) * (u - 0.6875) / 0.3125;
}

static int cmpd(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }

// The heights where column `col` (of `sides`) changes slope, plus both ends.
static int threadColumn(double pitch, double z0, double z1, int col, int sides, double *zs, int cap) {
	double off = pitch * (col % sides) / sides;
	int n = 0;
	zs[n++] = z0;
	for (int k = -1; ; k++) {
		double base = z0 + off + k * pitch;
		if (base > z1) break;
		for (int c = 0; c < 4; c++) {
			double z = base + PDThreadCorners[c] * pitch;
			if (z > z0 + 1e-6 && z < z1 - 1e-6 && n < cap - 1) zs[n++] = z;
		}
	}
	zs[n++] = z1;
	qsort(zs, (size_t)n, sizeof(double), cmpd);
	return n;
}

static void threadPoint(double rmin, double rmaj, double pitch, double z0, int col, int sides, double z, double *p) {
	double off = pitch * (col % sides) / sides;
	double u = fmod(z - z0 - off, pitch) / pitch;
	if (u < 0) u += 1;
	ring(threadRadius(u, rmin, rmaj), col, sides, 0, z, p);
}

// A threaded rod from z0 to z1. Each column round the axis follows the profile at its own phase (that's the
// helix); neighbouring columns are zipped together by height, and flat caps close the ends.
static void threadRodEx(Out *o, double rmin, double rmaj, double pitch, double z0, double z1, int sides, int capBottom, int capTop, int inward) {
	int cap = (int)((z1 - z0) / pitch * 4) + 16;
	double *za = malloc((size_t)cap * sizeof(double)), *zb = malloc((size_t)cap * sizeof(double));
	if (!za || !zb) { free(za); free(zb); o->oom = 1; return; }
	double cb[3] = {0, 0, z0}, ct[3] = {0, 0, z1};
	for (int i = 0; i < sides; i++) {
		int na = threadColumn(pitch, z0, z1, i, sides, za, cap), nb = threadColumn(pitch, z0, z1, i + 1, sides, zb, cap);
		int ia = 0, ib = 0;
		double A[3], B[3], N[3];
		threadPoint(rmin, rmaj, pitch, z0, i, sides, za[0], A);
		threadPoint(rmin, rmaj, pitch, z0, i + 1, sides, zb[0], B);
		if (capBottom) tri3(o, cb, B, A);
		while (ia < na - 1 || ib < nb - 1) {
			int advB = ia == na - 1 || (ib < nb - 1 && zb[ib + 1] <= za[ia + 1]);
			if (advB) { threadPoint(rmin, rmaj, pitch, z0, i + 1, sides, zb[++ib], N); if (inward) tri3(o, A, N, B); else tri3(o, A, B, N); memcpy(B, N, sizeof N); }
			else { threadPoint(rmin, rmaj, pitch, z0, i, sides, za[++ia], N); if (inward) tri3(o, A, N, B); else tri3(o, A, B, N); memcpy(A, N, sizeof N); }
		}
		if (capTop) tri3(o, ct, A, B);
	}
	free(za); free(zb);
}

static void threadRod(Out *o, double rmin, double rmaj, double pitch, double z0, double z1, int sides) {
	threadRodEx(o, rmin, rmaj, pitch, z0, z1, sides, 1, 1, 0);
}

// The flat ring between an outer and an inner closed loop at one height (both counter-clockwise round the
// axis, star-shaped about it), zipped by angle. up: facing +z.
typedef struct { double (*p)[3]; int n; } Loop;
static double angleOf(const double *p) { double a = atan2(p[1], p[0]); return a < 0 ? a + 2 * M_PI : a; }
static int loopStart(Loop l) { int b = 0; for (int i = 1; i < l.n; i++) if (angleOf(l.p[i]) < angleOf(l.p[b])) b = i; return b; }
static void annulus(Out *o, Loop outer, Loop inner, int up) {
	int so = loopStart(outer), si = loopStart(inner), io = 0, ii = 0;
	while (io < outer.n || ii < inner.n) {
		const double *O0 = outer.p[(so + io) % outer.n], *O1 = outer.p[(so + io + 1) % outer.n];
		const double *I0 = inner.p[(si + ii) % inner.n], *I1 = inner.p[(si + ii + 1) % inner.n];
		double ao = io < outer.n ? angleOf(O1) + (io + 1 == outer.n || angleOf(O1) < angleOf(O0) ? 2 * M_PI : 0) : 1e9;
		double ai = ii < inner.n ? angleOf(I1) + (ii + 1 == inner.n || angleOf(I1) < angleOf(I0) ? 2 * M_PI : 0) : 1e9;
		if (io < outer.n && angleOf(O0) < angleOf(outer.p[so]) - 1e-12) ao += 2 * M_PI;   // already wrapped
		if (ii < inner.n && angleOf(I0) < angleOf(inner.p[si]) - 1e-12) ai += 2 * M_PI;
		if (ao <= ai) { if (up) tri3(o, O0, O1, I0); else tri3(o, O0, I0, O1); io++; }
		else { if (up) tri3(o, O0, I1, I0); else tri3(o, O0, I0, I1); ii++; }
	}
}
static Loop loopNew(int n) { Loop l; l.n = n; l.p = malloc((size_t)n * sizeof *l.p); return l; }
static Loop circleLoop(double r, int sides, double phase, double z) {
	Loop l = loopNew(sides);
	if (l.p) for (int i = 0; i < sides; i++) ring(r, i, sides, phase, z, l.p[i]);
	return l;
}
static Loop threadLoop(double rmin, double rmaj, double pitch, double z0, int sides, double z) {
	Loop l = loopNew(sides);
	if (l.p) for (int i = 0; i < sides; i++) threadPoint(rmin, rmaj, pitch, z0, i, sides, z, l.p[i]);
	return l;
}

static int threadSides(double r) { int s = sidesFor(r); return s < 40 ? 40 : s; }

#pragma mark - Parts

// Bolts and nuts are stitched in one piece (no boolean operations): the head's open top is joined to the
// thread's bottom ring by a flat ring, so the mesh stays closed and as small as the thread itself.
int PDPartBolt(int size, float length, int head, int threaded, float clearance, PDCSGMesh *out) {
	const PDMetric *m = PDMetricSize(size);
	if (!m || length < 1 || length > 300) return -1;
	double r = m->d / 2 - clearance, rmin = r - 0.6134 * m->pitch, k = 0;
	int ts = threaded ? threadSides(r) : sidesFor(r);
	Out o = {0};
	Loop top = {0};
	if (head == PDHeadHex) {
		k = m->hexHeadH;
		double R = m->hexAF / sqrt(3.0), c = 0.3;   // a small bevel round the bottom
		double pr[4][2] = {{0, 0}, {R - c, 0}, {R, c}, {R, k}};
		lathe(&o, pr, 4, 6, M_PI / 6);
		top = circleLoop(R, 6, M_PI / 6, k);
	} else if (head == PDHeadSocket) {
		k = m->capH;
		double cr = m->capD / 2, e = cr * 0.08, kr = m->keyAF / sqrt(3.0), kd = k * 0.6;
		int cs = sidesFor(cr);
		double pr[3][2] = {{cr - e, 0}, {cr, e}, {cr, k}};
		lathe(&o, pr, 3, cs, 0);
		// the hex key recess, open at the bottom
		Loop outerB = circleLoop(cr - e, cs, 0, 0), keyB = circleLoop(kr, 6, 0, 0);
		if (!outerB.p || !keyB.p) { free(outerB.p); free(keyB.p); free(o.t); return -1; }
		annulus(&o, outerB, keyB, 0);
		double wall[3][2] = {{kr, 0}, {kr, kd}, {0, kd}};   // walls and ceiling face into the recess
		for (int i = 0; i < 6; i++) for (int q = 0; q < 2; q++) {
			double a[3], b[3], c[3], d[3];
			ring(wall[q][0], i, 6, 0, wall[q][1], a); ring(wall[q][0], i + 1, 6, 0, wall[q][1], b);
			ring(wall[q + 1][0], i + 1, 6, 0, wall[q + 1][1], c); ring(wall[q + 1][0], i, 6, 0, wall[q + 1][1], d);
			quad3(&o, a, d, c, b);
		}
		free(outerB.p); free(keyB.p);
		top = circleLoop(cr, cs, 0, k);
	} else if (head == PDHeadCountersunk) {
		k = (m->cskD - m->d) / 2;
		int cs = sidesFor(m->cskD / 2);
		double pr[3][2] = {{0, 0}, {m->cskD / 2, 0}, {m->d / 2, k}};
		lathe(&o, pr, 3, cs, 0);
		top = circleLoop(m->d / 2, cs, 0, k);
	}
	int hasHead = head != PDHeadNone;
	if (hasHead) {
		Loop shaftRing = threaded ? threadLoop(rmin, r, m->pitch, k, ts, k) : circleLoop(r, ts, 0, k);
		if (!top.p || !shaftRing.p) { free(top.p); free(shaftRing.p); free(o.t); return -1; }
		annulus(&o, top, shaftRing, 1);
		free(top.p); free(shaftRing.p);
	}
	double z1 = k + length;
	if (threaded) threadRodEx(&o, rmin, r, m->pitch, k, z1, ts, !hasHead, 1, 0);
	else if (hasHead) { double pr[3][2] = {{r, k}, {r, z1}, {0, z1}}; lathe(&o, pr, 3, ts, 0); }
	else { double pr[4][2] = {{0, 0}, {r, 0}, {r, z1}, {0, z1}}; lathe(&o, pr, 4, ts, 0); }
	return finish(&o, out);
}

int PDPartNut(int size, float height, int threaded, float clearance, PDCSGMesh *out) {
	const PDMetric *m = PDMetricSize(size);
	if (!m || height < 0.5f || height > 100) return -1;
	double R = m->hexAF / sqrt(3.0), h = height;
	double rmaj = m->d / 2 + clearance, rmin = m->d / 2 - 0.5413 * m->pitch + clearance;
	int ts = threaded ? threadSides(rmaj) : sidesFor(rmaj);
	Out o = {0};
	double pr[2][2] = {{R, 0}, {R, h}};
	lathe(&o, pr, 2, 6, M_PI / 6);
	Loop hb = circleLoop(R, 6, M_PI / 6, 0), ht = circleLoop(R, 6, M_PI / 6, h);
	Loop ib = threaded ? threadLoop(rmin, rmaj, m->pitch, 0, ts, 0) : circleLoop(rmaj, ts, 0, 0);
	Loop it = threaded ? threadLoop(rmin, rmaj, m->pitch, 0, ts, h) : circleLoop(rmaj, ts, 0, h);
	if (!hb.p || !ht.p || !ib.p || !it.p) { free(hb.p); free(ht.p); free(ib.p); free(it.p); free(o.t); return -1; }
	annulus(&o, hb, ib, 0);
	annulus(&o, ht, it, 1);
	free(hb.p); free(ht.p); free(ib.p); free(it.p);
	if (threaded) threadRodEx(&o, rmin, rmaj, m->pitch, 0, h, ts, 0, 0, 1);
	else { double hp[2][2] = {{rmaj, h}, {rmaj, 0}}; lathe(&o, hp, 2, ts, 0); }
	return finish(&o, out);
}

int PDPartThreadedHole(int size, float depth, float clearance, PDCSGMesh *out) {
	const PDMetric *m = PDMetricSize(size);
	if (!m || depth < 0.5f || depth > 300) return -1;
	Out o = {0};
	double rmaj = m->d / 2 + clearance, rmin = m->d / 2 - 0.5413 * m->pitch + clearance;
	threadRod(&o, rmin, rmaj, m->pitch, 0, depth, threadSides(rmaj));
	return finish(&o, out);
}

int PDPartScrewHole(int size, float depth, int style, PDCSGMesh *out) {
	const PDMetric *m = PDMetricSize(size);
	if (!m || depth < 0.5f || depth > 300) return -1;
	double rc = m->d / 2 + 0.2;   // ISO 273 "normal" clearance, roughly
	Out o = {0};
	if (style == PDScrewHoleCountersink) {
		double R = m->cskD / 2 + 0.3, h = R - rc;   // 90°
		if (h > depth) h = depth;
		double pr[5][2] = {{0, 0}, {rc, 0}, {rc, depth - h}, {rc + h, depth}, {0, depth}};
		lathe(&o, pr, 5, sidesFor(R), 0);
	} else if (style == PDScrewHoleCounterbore) {
		double R = m->capD / 2 + 0.4, h = m->capH + 0.3;
		if (h > depth) h = depth;
		double pr[6][2] = {{0, 0}, {rc, 0}, {rc, depth - h}, {R, depth - h}, {R, depth}, {0, depth}};
		lathe(&o, pr, 6, sidesFor(R), 0);
	} else {
		double pr[4][2] = {{0, 0}, {rc, 0}, {rc, depth}, {0, depth}};
		lathe(&o, pr, 4, sidesFor(rc), 0);
	}
	return finish(&o, out);
}

// Profile points of a rounded or bevelled rim: from (r, zStart) out to (r + s, zEnd).
static int rim(double (*pr)[2], int n, int edge, double r, double s, double zs, double ze, int down) {
	int steps = edge == PDEdgeFillet ? 8 : 1;
	for (int i = 1; i <= steps; i++) {
		double t = (double)i / steps, x, z;
		if (edge == PDEdgeFillet) {   // quarter circle centred at (r + s, zs), from (r, zs) to (r + s, ze)
			double a = t * M_PI / 2;
			x = r + s - s * cos(a); z = zs + (ze - zs) * sin(a);
		} else { x = r + s * t; z = zs + (ze - zs) * t; }
		pr[n][0] = x; pr[n][1] = z; n++;
	}
	(void)down;
	return n;
}

int PDPartEdgeHole(float diameter, float depth, int edge, float s, int bothEnds, PDCSGMesh *out) {
	double r = diameter / 2;
	if (r <= 0 || depth <= 0 || depth > 300 || r > 150) return -1;
	if (edge == PDEdgeNone) s = 0;
	if (s > depth / (bothEnds ? 2 : 1)) s = depth / (bothEnds ? 2 : 1);
	double pr[24][2];
	int n = 0;
	pr[n][0] = 0; pr[n][1] = 0; n++;
	if (s > 0 && bothEnds) {
		// bottom rim, walked from the outside in: mirror of a top rim
		double tmp[12][2];
		int m = rim(tmp, 0, edge, r, s, s, 0, 1);
		pr[n][0] = r + s; pr[n][1] = 0; n++;
		for (int i = m - 2; i >= 0; i--) { pr[n][0] = tmp[i][0]; pr[n][1] = tmp[i][1]; n++; }
		pr[n][0] = r; pr[n][1] = s; n++;
	} else { pr[n][0] = r; pr[n][1] = 0; n++; }
	if (s > 0) {
		if (depth - s > pr[n - 1][1] + 1e-6) { pr[n][0] = r; pr[n][1] = depth - s; n++; }
		n = rim(pr, n, edge, r, s, depth - s, depth, 0);
	} else { pr[n][0] = r; pr[n][1] = depth; n++; }
	pr[n][0] = 0; pr[n][1] = depth; n++;
	Out o = {0};
	lathe(&o, (const double (*)[2])pr, n, sidesFor(r + s), 0);
	return finish(&o, out);
}

int PDPartRoundedCylinder(float diameter, float h, int topEdge, float ts, int bottomEdge, float bs, PDCSGMesh *out) {
	double R = diameter / 2;
	if (R <= 0 || h <= 0 || R > 200 || h > 300) return -1;
	if (topEdge == PDEdgeNone) ts = 0;
	if (bottomEdge == PDEdgeNone) bs = 0;
	if (ts > R) ts = (float)R;
	if (bs > R) bs = (float)R;
	if (ts + bs > h) { double k = h / (ts + bs); ts *= k; bs *= k; }
	double pr[24][2];
	int n = 0;
	pr[n][0] = 0; pr[n][1] = 0; n++;
	if (bs > 0) {
		pr[n][0] = R - bs; pr[n][1] = 0; n++;
		int steps = bottomEdge == PDEdgeFillet ? 8 : 1;
		for (int i = 1; i <= steps; i++) {
			double t = (double)i / steps, a = t * M_PI / 2;
			if (bottomEdge == PDEdgeFillet) { pr[n][0] = R - bs + bs * sin(a); pr[n][1] = bs - bs * cos(a); }
			else { pr[n][0] = R - bs + bs * t; pr[n][1] = bs * t; }
			n++;
		}
	} else { pr[n][0] = R; pr[n][1] = 0; n++; }
	if (h - ts > pr[n - 1][1] + 1e-6) { pr[n][0] = R; pr[n][1] = h - ts; n++; }
	if (ts > 0) {
		int steps = topEdge == PDEdgeFillet ? 8 : 1;
		for (int i = 1; i <= steps; i++) {
			double t = (double)i / steps, a = t * M_PI / 2;
			if (topEdge == PDEdgeFillet) { pr[n][0] = R - ts + ts * cos(a); pr[n][1] = h - ts + ts * sin(a); }
			else { pr[n][0] = R - ts * t; pr[n][1] = h - ts + ts * t; }
			n++;
		}
	}
	if (pr[n - 1][0] > 0) { pr[n][0] = 0; pr[n][1] = h; n++; }
	Out o = {0};
	lathe(&o, (const double (*)[2])pr, n, sidesFor(R), 0);
	return finish(&o, out);
}

// Rounded box: a sphere split into eight octants, each pushed out to a corner of the inner box; the bands
// between them are the flat faces. One segment per quarter turn gives a chamfer instead.
int PDPartRoundedBox(float w, float d, float h, float radius, int edge, PDCSGMesh *out) {
	if (w <= 0 || d <= 0 || h <= 0 || w > 400 || d > 400 || h > 400) return -1;
	double r = radius;
	if (edge == PDEdgeNone || r < 0) r = 0;
	double lim = fmin(w, fmin(d, h)) / 2;
	if (r > lim) r = lim;
	double ax = w / 2 - r, ay = d / 2 - r, az = h / 2 - r;
	int n = edge == PDEdgeChamfer ? 1 : 6;
	if (r == 0) n = 1;
	int cols = 4 * (n + 1), rows = 2 * (n + 1);
	double (*P)[3] = malloc((size_t)cols * rows * sizeof *P);
	if (!P) return -1;
	for (int c = 0; c < cols; c++) {
		int q = c / (n + 1), k = c % (n + 1);
		double lon = q * M_PI / 2 + k * (M_PI / 2) / n;
		double sx = (q == 0 || q == 3) ? 1 : -1, sy = q < 2 ? 1 : -1;
		double cl = k == 0 ? (q == 0 ? 1 : q == 2 ? -1 : 0) : k == n ? (q == 3 ? 1 : q == 1 ? -1 : 0) : cos(lon);
		double sl = k == 0 ? (q == 1 ? 1 : q == 3 ? -1 : 0) : k == n ? (q == 0 ? 1 : q == 2 ? -1 : 0) : sin(lon);
		for (int rr = 0; rr < rows; rr++) {
			int hh = rr / (n + 1), j = rr % (n + 1);
			double lat = -M_PI / 2 + hh * M_PI / 2 + j * (M_PI / 2) / n;
			double cz = (hh == 0 && j == 0) || (hh == 1 && j == n) ? 0 : (hh == 0 && j == n) || (hh == 1 && j == 0) ? 1 : cos(lat);
			double sz = (hh == 0 && j == 0) ? -1 : (hh == 1 && j == n) ? 1 : (hh == 0 && j == n) || (hh == 1 && j == 0) ? 0 : sin(lat);
			double *p = P[c * rows + rr];
			p[0] = sx * ax + r * cz * cl; p[1] = sy * ay + r * cz * sl; p[2] = h / 2 + (hh ? 1 : -1) * az + r * sz;
			for (int t = 0; t < 3; t++) if (p[t] == 0) p[t] = 0;   // no -0
		}
	}
	Out o = {0};
	for (int c = 0; c < cols; c++)
		for (int rr = 0; rr + 1 < rows; rr++)
			quad3(&o, P[c * rows + rr], P[((c + 1) % cols) * rows + rr], P[((c + 1) % cols) * rows + rr + 1], P[c * rows + rr + 1]);
	// The flat top and bottom between the four pole points.
	double *t0 = P[0 * rows + rows - 1], *t1 = P[(n + 1) * rows + rows - 1], *t2 = P[2 * (n + 1) * rows + rows - 1], *t3 = P[3 * (n + 1) * rows + rows - 1];
	quad3(&o, t0, t1, t2, t3);
	double *b0 = P[0], *b1 = P[(n + 1) * rows], *b2 = P[2 * (n + 1) * rows], *b3 = P[3 * (n + 1) * rows];
	quad3(&o, b0, b3, b2, b1);
	free(P);
	return finish(&o, out);
}

#pragma mark - Gear

static double involuteAngle(double rb, double r) { if (r <= rb) return 0; double a = acos(rb / r); return tan(a) - a; }

int PDPartGear(int teeth, float module, float thickness, float bore, PDCSGMesh *out) {
	if (teeth < 6 || teeth > 200 || module < 0.3f || module > 10 || thickness <= 0 || thickness > 200) return -1;
	double pr = module * teeth / 2.0, ra = pr + module, rf = pr - 1.25 * module, rb = pr * cos(20 * M_PI / 180);
	if (rf < 0.5) rf = 0.5;
	double rbore = bore / 2;
	if (rbore >= rf - 0.5) rbore = 0;
	double half = M_PI / (2 * teeth) + involuteAngle(rb, pr);   // half the tooth's angular width at the base, measured as ψ(r) = half − inv(r)
	while (ra > pr && half - involuteAngle(rb, ra) < 0.25 * M_PI / (2 * teeth)) ra -= 0.02 * module;   // no pointed teeth
	int flank = 6;
	int per = 2 * (flank + 1) + 2 + 3, cap = teeth * per + 8;
	double (*O)[2] = malloc((size_t)cap * sizeof *O);   // outline: (angle, radius), angle increasing
	if (!O) return -1;
	int n = 0;
	for (int t = 0; t < teeth; t++) {
		double c = 2 * M_PI * t / teeth;
		double rlo = rf > rb ? rf : rb;
		// rising flank: root circle, then up the involute
		for (int i = 0; i <= flank; i++) {
			double r = rlo + (ra - rlo) * i / flank;
			double psi = half - involuteAngle(rb, r);
			if (i == 0 && rf < rb) { O[n][0] = c - psi; O[n][1] = rf; n++; }
			O[n][0] = c - psi; O[n][1] = r; n++;
		}
		// falling flank
		for (int i = flank; i >= 0; i--) {
			double r = rlo + (ra - rlo) * i / flank;
			double psi = half - involuteAngle(rb, r);
			O[n][0] = c + psi; O[n][1] = r; n++;
			if (i == 0 && rf < rb) { O[n][0] = c + psi; O[n][1] = rf; n++; }
		}
		// root between this tooth and the next
		double psiR = half - involuteAngle(rb, rlo), next = 2 * M_PI * (t + 1) / teeth;
		double a0 = c + psiR, a1 = next - psiR;
		for (int i = 1; i <= 2; i++) { O[n][0] = a0 + (a1 - a0) * i / 3; O[n][1] = rf; n++; }
	}
	Out o = {0};
	double H = thickness;
	// sides
	for (int i = 0; i < n; i++) {
		int j = (i + 1) % n;
		double a[3] = {O[i][1] * cos(O[i][0]), O[i][1] * sin(O[i][0]), 0}, b[3] = {O[j][1] * cos(O[j][0]), O[j][1] * sin(O[j][0]), 0};
		double at[3] = {a[0], a[1], H}, bt[3] = {b[0], b[1], H};
		quad3(&o, a, b, bt, at);
	}
	if (rbore <= 0) {
		double cb[3] = {0, 0, 0}, ct[3] = {0, 0, H};
		for (int i = 0; i < n; i++) {
			int j = (i + 1) % n;
			double a[3] = {O[i][1] * cos(O[i][0]), O[i][1] * sin(O[i][0]), 0}, b[3] = {O[j][1] * cos(O[j][0]), O[j][1] * sin(O[j][0]), 0};
			double at[3] = {a[0], a[1], H}, bt[3] = {b[0], b[1], H};
			tri3(&o, cb, b, a);
			tri3(&o, ct, at, bt);
		}
	} else {
		int m = sidesFor(rbore);
		// bore wall, facing in
		for (int i = 0; i < m; i++) {
			double a[3], b[3], at[3], bt[3];
			ring(rbore, i, m, 0, 0, a); ring(rbore, i + 1, m, 0, 0, b); ring(rbore, i, m, 0, H, at); ring(rbore, i + 1, m, 0, H, bt);
			quad3(&o, a, at, bt, b);
		}
		// top and bottom rings: zip outline and bore by angle (both run counter-clockwise from about angle 0)
		int io = 0, ib = 0;
		double off = O[0][0];   // outline starts slightly below 0
		while (io < n || ib < m) {
			double ao = io < n ? O[io + 1 < n ? io + 1 : 0][0] + (io + 1 < n ? 0 : 2 * M_PI) - off : 1e9;
			double ab = ib < m ? 2 * M_PI * (ib + 1) / m - off : 1e9;
			int i0 = io % n, i1 = (io + 1) % n;
			double A0[3] = {O[i0][1] * cos(O[i0][0]), O[i0][1] * sin(O[i0][0]), 0};
			double B0[3];
			ring(rbore, ib, m, 0, 0, B0);
			if (ao <= ab) {
				double A1[3] = {O[i1][1] * cos(O[i1][0]), O[i1][1] * sin(O[i1][0]), 0};
				double A0t[3] = {A0[0], A0[1], H}, A1t[3] = {A1[0], A1[1], H}, B0t[3] = {B0[0], B0[1], H};
				tri3(&o, A0t, A1t, B0t);
				tri3(&o, A0, B0, A1);
				io++;
			} else {
				double B1[3];
				ring(rbore, ib + 1, m, 0, 0, B1);
				double A0t[3] = {A0[0], A0[1], H}, B0t[3] = {B0[0], B0[1], H}, B1t[3] = {B1[0], B1[1], H};
				tri3(&o, A0t, B1t, B0t);
				tri3(&o, A0, B0, B1);
				ib++;
			}
		}
	}
	free(O);
	return finish(&o, out);
}

#pragma mark - Basic shapes with options

// A closed profile loop (radius, z), counter-clockwise in the (r, z) plane and clear of the axis, turned round z.
static void revolveLoop(Out *o, const double (*pr)[2], int np, int sides, double phase) {
	for (int i = 0; i < sides; i++)
		for (int k = 0; k < np; k++) {
			int k1 = (k + 1) % np;
			double a[3], b[3], c[3], d[3];
			ring(pr[k][0], i, sides, phase, pr[k][1], a);
			ring(pr[k][0], i + 1, sides, phase, pr[k][1], b);
			ring(pr[k1][0], i + 1, sides, phase, pr[k1][1], c);
			ring(pr[k1][0], i, sides, phase, pr[k1][1], d);
			quad3(o, a, b, c, d);
		}
}

// Few sides: a flat side facing front (-y), like a printed nut. Many: the usual round.
static double polyPhase(int sides) { return sides <= 16 ? -M_PI / 2 + M_PI / sides : 0; }
static int roundSides(int sides, double r) { return sides >= 3 ? (sides > 256 ? 256 : sides) : sidesFor(r); }

int PDShapeBox(float w, float d, float h, int edge, float radius, int which, PDCSGMesh *out) {
	if (which == PDBoxAllEdges || edge == PDEdgeNone || radius <= 0) return PDPartRoundedBox(w, d, h, radius, edge, out);
	if (w <= 0 || d <= 0 || h <= 0 || w > 400 || d > 400 || h > 400) return -1;
	int flatTop = which == PDBoxSideEdges, flatBottom = 1;
	double r = radius, lim = fmin(w, d) / 2;
	if (!flatTop && h < lim) lim = h;
	if (r > lim) r = lim;
	double ax = w / 2 - r, ay = d / 2 - r;
	int n = edge == PDEdgeChamfer ? 1 : 6;
	int cols = 4 * (n + 1);
	// Rows from the bottom: (cos lat, sin lat, z of the centre).
	double rows[16][3];
	int nr = 0;
	(void)flatBottom;
	rows[nr][0] = 1; rows[nr][1] = 0; rows[nr][2] = 0; nr++;
	if (flatTop) { rows[nr][0] = 1; rows[nr][1] = 0; rows[nr][2] = h; nr++; }
	else for (int j = 0; j <= n; j++) {
		double lat = j * (M_PI / 2) / n;
		rows[nr][0] = j == n ? 0 : j == 0 ? 1 : cos(lat); rows[nr][1] = j == n ? 1 : j == 0 ? 0 : sin(lat); rows[nr][2] = h - r; nr++;
	}
	double (*P)[3] = malloc((size_t)cols * nr * sizeof *P);
	if (!P) return -1;
	for (int c = 0; c < cols; c++) {
		int q = c / (n + 1), k = c % (n + 1);
		double lon = q * M_PI / 2 + k * (M_PI / 2) / n;
		double sx = (q == 0 || q == 3) ? 1 : -1, sy = q < 2 ? 1 : -1;
		double cl = k == 0 ? (q == 0 ? 1 : q == 2 ? -1 : 0) : k == n ? (q == 3 ? 1 : q == 1 ? -1 : 0) : cos(lon);
		double sl = k == 0 ? (q == 1 ? 1 : q == 3 ? -1 : 0) : k == n ? (q == 0 ? 1 : q == 2 ? -1 : 0) : sin(lon);
		for (int rr = 0; rr < nr; rr++) {
			double *p = P[c * nr + rr];
			p[0] = sx * ax + r * rows[rr][0] * cl; p[1] = sy * ay + r * rows[rr][0] * sl; p[2] = rows[rr][2] + r * rows[rr][1];
			for (int t = 0; t < 3; t++) if (p[t] == 0) p[t] = 0;
		}
	}
	Out o = {0};
	for (int c = 0; c < cols; c++)
		for (int rr = 0; rr + 1 < nr; rr++)
			quad3(&o, P[c * nr + rr], P[((c + 1) % cols) * nr + rr], P[((c + 1) % cols) * nr + rr + 1], P[c * nr + rr + 1]);
	double cb[3] = {0, 0, 0}, ct[3] = {0, 0, h};
	for (int c = 0; c < cols; c++) tri3(&o, cb, P[((c + 1) % cols) * nr], P[c * nr]);   // flat bottom
	if (flatTop) for (int c = 0; c < cols; c++) tri3(&o, ct, P[c * nr + nr - 1], P[((c + 1) % cols) * nr + nr - 1]);
	else {   // the four pole points
		double *t0 = P[0 * nr + nr - 1], *t1 = P[(n + 1) * nr + nr - 1], *t2 = P[2 * (n + 1) * nr + nr - 1], *t3 = P[3 * (n + 1) * nr + nr - 1];
		quad3(&o, t0, t1, t2, t3);
	}
	free(P);
	return finish(&o, out);
}

// Profile of a cylinder wall from (r, 0) to (r, h) with its two corners rounded or bevelled, appended to pr.
// out: +1 the solid is inside r (an outer wall, walked upward), -1 outside it (an inner wall, walked downward).
static int wallProfile(double (*pr)[2], int n, double r, double h, int bottomEdge, double bs, int topEdge, double ts, int out) {
	int sb = bottomEdge == PDEdgeFillet ? 8 : 1, st = topEdge == PDEdgeFillet ? 8 : 1;
	if (out > 0) {
		if (bs > 0) for (int i = 0; i <= sb; i++) {
			double t = (double)i / sb, a = t * M_PI / 2;
			if (bottomEdge == PDEdgeFillet) { pr[n][0] = r - bs + bs * sin(a); pr[n][1] = bs - bs * cos(a); }
			else { pr[n][0] = r - bs + bs * t; pr[n][1] = bs * t; }
			n++;
		} else { pr[n][0] = r; pr[n][1] = 0; n++; }
		if (ts > 0) for (int i = 0; i <= st; i++) {
			double t = (double)i / st, a = t * M_PI / 2;
			if (topEdge == PDEdgeFillet) { pr[n][0] = r - ts + ts * cos(a); pr[n][1] = h - ts + ts * sin(a); }
			else { pr[n][0] = r - ts * t; pr[n][1] = h - ts + ts * t; }
			n++;
		} else { pr[n][0] = r; pr[n][1] = h; n++; }
	} else {   // inner wall, top to bottom; the material is at r and beyond
		if (ts > 0) for (int i = 0; i <= st; i++) {
			double t = (double)i / st, a = t * M_PI / 2;
			if (topEdge == PDEdgeFillet) { pr[n][0] = r + ts - ts * sin(a); pr[n][1] = h - ts + ts * cos(a); }
			else { pr[n][0] = r + ts - ts * t; pr[n][1] = h - ts * t; }
			n++;
		} else { pr[n][0] = r; pr[n][1] = h; n++; }
		if (bs > 0) for (int i = 0; i <= sb; i++) {
			double t = (double)i / sb, a = t * M_PI / 2;
			if (bottomEdge == PDEdgeFillet) { pr[n][0] = r + bs - bs * cos(a); pr[n][1] = bs - bs * sin(a); }
			else { pr[n][0] = r + bs * t; pr[n][1] = bs - bs * t; }
			n++;
		} else { pr[n][0] = r; pr[n][1] = 0; n++; }
	}
	// drop repeats where a flat stretch has no length
	int m = 0;
	for (int i = 0; i < n; i++) if (!m || fabs(pr[i][0] - pr[m - 1][0]) > 1e-9 || fabs(pr[i][1] - pr[m - 1][1]) > 1e-9) { pr[m][0] = pr[i][0]; pr[m][1] = pr[i][1]; m++; }
	return m;
}

int PDShapeCylinder(float diameter, float h, int sides, int topEdge, float ts, int bottomEdge, float bs, PDCSGMesh *out) {
	double R = diameter / 2;
	if (R <= 0 || h <= 0 || R > 200 || h > 400) return -1;
	if (topEdge == PDEdgeNone || ts < 0) ts = 0;
	if (bottomEdge == PDEdgeNone || bs < 0) bs = 0;
	if (ts > R) ts = (float)R;
	if (bs > R) bs = (float)R;
	if (ts + bs > h) { double k = h / (ts + bs); ts *= k; bs *= k; }
	double pr[32][2];
	int n = 0;
	pr[n][0] = 0; pr[n][1] = 0; n++;
	n = wallProfile(pr, n, R, h, bottomEdge, bs, topEdge, ts, 1);
	if (pr[n - 1][0] > 1e-9) { pr[n][0] = 0; pr[n][1] = h; n++; } else pr[n - 1][0] = 0;
	if (pr[1][0] <= 1e-9) pr[1][0] = 0;
	int s = roundSides(sides, R);
	Out o = {0};
	lathe(&o, (const double (*)[2])pr, n, s, polyPhase(s));
	return finish(&o, out);
}

int PDShapeCone(float diameter, float topDiameter, float h, int sides, PDCSGMesh *out) {
	double R = diameter / 2, Rt = topDiameter / 2;
	if (R <= 0 || h <= 0 || R > 200 || h > 400 || Rt < 0 || Rt > 400) return -1;
	double pr[4][2] = {{0, 0}, {R, 0}, {Rt, h}, {0, h}};
	int s = roundSides(sides, R > Rt ? R : Rt);
	if (Rt <= 1e-6) pr[2][0] = 0;
	Out o = {0};
	lathe(&o, (const double (*)[2])pr, Rt > 1e-6 ? 4 : 3, s, polyPhase(s));
	return finish(&o, out);
}

int PDShapeTube(float diameter, float h, float wall, int sides, int edge, float es, int bothEnds, PDCSGMesh *out) {
	double R = diameter / 2;
	if (R <= 0 || h <= 0 || R > 200 || h > 400 || wall <= 0) return -1;
	if (wall >= R) return PDShapeCylinder(diameter, h, sides, edge, es, bothEnds ? edge : PDEdgeNone, es, out);
	double ri = R - wall;
	if (edge == PDEdgeNone || es < 0) es = 0;
	if (es > wall / 2) es = (float)(wall / 2);
	if (es > h / (bothEnds ? 2 : 1)) es = (float)(h / (bothEnds ? 2 : 1));
	double bs = bothEnds ? es : 0;
	double pr[48][2];
	int n = wallProfile(pr, 0, R, h, edge, bs, edge, es, 1);         // outside, upward
	n = wallProfile(pr, n, ri, h, edge, bs, edge, es, -1);           // inside, downward
	int s = roundSides(sides, R);
	Out o = {0};
	revolveLoop(&o, (const double (*)[2])pr, n, s, polyPhase(s));
	return finish(&o, out);
}

int PDShapePyramid(float diameter, float h, int sides, PDCSGMesh *out) {
	if (diameter <= 0 || h <= 0 || sides < 3 || sides > 64) return -1;
	double pr[3][2] = {{0, 0}, {diameter / 2, 0}, {0, h}};
	Out o = {0};
	lathe(&o, (const double (*)[2])pr, 3, sides, polyPhase(sides));
	return finish(&o, out);
}

int PDShapeSphere(float diameter, int segments, int dome, PDCSGMesh *out) {
	if (diameter <= 0 || segments < 8 || segments > 256) return -1;
	double R = diameter / 2;
	int rings = dome ? segments / 4 : segments / 2;
	if (rings < 2) rings = 2;
	double pr[130][2];
	int n = 0;
	for (int k = 0; k <= rings; k++) {   // bottom to top; angle from the top
		double t = dome ? M_PI / 2 * (1 - (double)k / rings) : M_PI * (1 - (double)k / rings);
		pr[n][0] = k == rings ? 0 : R * sin(t);
		pr[n][1] = dome ? R * cos(t) : R + R * cos(t);
		if (k == 0) { if (dome) pr[n][1] = 0; else pr[n][0] = 0; }
		n++;
	}
	if (dome) { for (int i = n; i > 0; i--) { pr[i][0] = pr[i - 1][0]; pr[i][1] = pr[i - 1][1]; } pr[0][0] = 0; pr[0][1] = 0; n++; }
	Out o = {0};
	lathe(&o, (const double (*)[2])pr, n, segments, 0);
	return finish(&o, out);
}

int PDShapeTorus(float diameter, float tube, int sides, int tubeSides, PDCSGMesh *out) {
	double Ro = diameter / 2, r = tube / 2;
	if (Ro <= 0 || r <= 0 || Ro > 200 || tubeSides < 3 || tubeSides > 128) return -1;
	if (r > Ro * 0.49) r = Ro * 0.49;
	double Rc = Ro - r, pr[130][2];
	for (int j = 0; j < tubeSides; j++) {   // counter-clockwise in (r, z), starting at the bottom
		double a = -M_PI / 2 + 2 * M_PI * j / tubeSides;
		pr[j][0] = Rc + r * cos(a); pr[j][1] = r + r * sin(a);
	}
	int s = roundSides(sides, Ro);
	Out o = {0};
	revolveLoop(&o, (const double (*)[2])pr, tubeSides, s, polyPhase(s));
	return finish(&o, out);
}
