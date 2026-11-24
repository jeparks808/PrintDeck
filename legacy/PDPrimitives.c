#include "PDPrimitives.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define SIDES 48   // round shapes: segments around

typedef struct { float *t; int n, cap, oom; } Out;

static void tri(Out *o, double ax, double ay, double az, double bx, double by, double bz, double cx, double cy, double cz) {
	if (o->oom) return;
	if (o->n == o->cap) {
		int cap = o->cap ? o->cap * 2 : 128;
		float *t = realloc(o->t, (size_t)cap * 9 * sizeof(float));
		if (!t) { o->oom = 1; return; }
		o->t = t; o->cap = cap;
	}
	float *t = o->t + (size_t)o->n++ * 9;
	t[0] = (float)ax; t[1] = (float)ay; t[2] = (float)az; t[3] = (float)bx; t[4] = (float)by; t[5] = (float)bz;
	t[6] = (float)cx; t[7] = (float)cy; t[8] = (float)cz;
}
static void quad(Out *o, const double *a, const double *b, const double *c, const double *d) {   // a b c d counter-clockwise
	tri(o, a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2]);
	tri(o, a[0], a[1], a[2], c[0], c[1], c[2], d[0], d[1], d[2]);
}

// A solid of revolution about z from a profile of (radius, z) points, bottom to top. Zero radius at an end
// closes it with a point; otherwise a flat cap.
static void lathe(Out *o, const double (*pr)[2], int np, int sides) {
	for (int i = 0; i < sides; i++) {
		double a0 = 2 * M_PI * i / sides, a1 = 2 * M_PI * (i + 1) / sides;
		double c0 = cos(a0), s0 = sin(a0), c1 = cos(a1), s1 = sin(a1);
		for (int k = 0; k + 1 < np; k++) {
			double r0 = pr[k][0], z0 = pr[k][1], r1 = pr[k + 1][0], z1 = pr[k + 1][1];
			double p00[3] = {r0 * c0, r0 * s0, z0}, p01[3] = {r0 * c1, r0 * s1, z0}, p10[3] = {r1 * c0, r1 * s0, z1}, p11[3] = {r1 * c1, r1 * s1, z1};
			if (r0 < 1e-9) tri(o, p00[0], p00[1], p00[2], p11[0], p11[1], p11[2], p10[0], p10[1], p10[2]);
			else if (r1 < 1e-9) tri(o, p00[0], p00[1], p00[2], p01[0], p01[1], p01[2], p10[0], p10[1], p10[2]);
			else quad(o, p00, p01, p11, p10);
		}
		if (pr[0][0] > 1e-9) { double r = pr[0][0], z = pr[0][1]; tri(o, 0, 0, z, r * c1, r * s1, z, r * c0, r * s0, z); }
		if (pr[np - 1][0] > 1e-9) { double r = pr[np - 1][0], z = pr[np - 1][1]; tri(o, 0, 0, z, r * c0, r * s0, z, r * c1, r * s1, z); }
	}
}

// A prism along y from a counter-clockwise (x right, z up) outline.
static void prism(Out *o, const double (*pt)[2], int n) {
	double y0 = -0.5, y1 = 0.5;
	for (int i = 0; i < n; i++) {
		int j = (i + 1) % n;
		double a[3] = {pt[i][0], y0, pt[i][1]}, b[3] = {pt[j][0], y0, pt[j][1]}, c[3] = {pt[j][0], y1, pt[j][1]}, d[3] = {pt[i][0], y1, pt[i][1]};
		quad(o, a, d, c, b);
	}
	for (int i = 1; i + 1 < n; i++) {   // convex outlines: fans (the -y end faces -y)
		tri(o, pt[0][0], y0, pt[0][1], pt[i][0], y0, pt[i][1], pt[i + 1][0], y0, pt[i + 1][1]);
		tri(o, pt[0][0], y1, pt[0][1], pt[i + 1][0], y1, pt[i + 1][1], pt[i][0], y1, pt[i][1]);
	}
}

int PDPrimitiveMesh(const char *kind, PDCSGMesh *out) {
	Out o = {0};
	out->tris = NULL; out->count = 0;
	if (!strcmp(kind, "box")) {
		double v[8][3];
		for (int i = 0; i < 8; i++) { v[i][0] = i & 1 ? 0.5 : -0.5; v[i][1] = i & 2 ? 0.5 : -0.5; v[i][2] = i & 4 ? 0.5 : -0.5; }
		static const int f[6][4] = {{0, 2, 3, 1}, {4, 5, 7, 6}, {0, 1, 5, 4}, {2, 6, 7, 3}, {0, 4, 6, 2}, {1, 3, 7, 5}};
		for (int i = 0; i < 6; i++) quad(&o, v[f[i][0]], v[f[i][1]], v[f[i][2]], v[f[i][3]]);
	} else if (!strcmp(kind, "cylinder")) {
		double p[2][2] = {{0.5, -0.5}, {0.5, 0.5}};
		lathe(&o, (const double (*)[2])p, 2, SIDES);
	} else if (!strcmp(kind, "cone")) {
		double p[2][2] = {{0.5, -0.5}, {0, 0.5}};
		lathe(&o, (const double (*)[2])p, 2, SIDES);
	} else if (!strcmp(kind, "sphere") || !strcmp(kind, "dome")) {
		int dome = !strcmp(kind, "dome"), rings = dome ? 8 : 16;
		double p[17][2];
		for (int k = 0; k <= rings; k++) {   // bottom to top
			double t = dome ? M_PI / 2 * (1 - (double)k / rings) : M_PI * (1 - (double)k / rings);   // angle from the top
			p[k][0] = k == rings ? 0 : 0.5 * sin(t);
			p[k][1] = dome ? -0.5 + cos(t) : 0.5 * cos(t);
		}
		lathe(&o, (const double (*)[2])p, rings + 1, SIDES * 2 / 3);
	} else if (!strcmp(kind, "pyramid")) {
		lathe(&o, (const double (*)[2])(double[2][2]){{0.5 * M_SQRT2, -0.5}, {0, 0.5}}, 2, 4);
		// lathe's square is turned 0..90°; rotate it 45° so the base fills the unit square
		for (int i = 0; i < o.n * 3; i++) {
			float *v = o.t + i * 3, x = v[0], y = v[1];
			v[0] = (float)((x - y) * M_SQRT1_2); v[1] = (float)((x + y) * M_SQRT1_2);
		}
	} else if (!strcmp(kind, "roof")) {
		double p[3][2] = {{-0.5, -0.5}, {0.5, -0.5}, {0, 0.5}};
		prism(&o, (const double (*)[2])p, 3);
	} else if (!strcmp(kind, "wedge")) {
		double p[3][2] = {{-0.5, -0.5}, {0.5, -0.5}, {-0.5, 0.5}};
		prism(&o, (const double (*)[2])p, 3);
	} else if (!strcmp(kind, "tube")) {
		double ri = 0.3, ro = 0.5;
		for (int i = 0; i < SIDES; i++) {
			double a0 = 2 * M_PI * i / SIDES, a1 = 2 * M_PI * (i + 1) / SIDES;
			double c0 = cos(a0), s0 = sin(a0), c1 = cos(a1), s1 = sin(a1);
			double ob0[3] = {ro * c0, ro * s0, -0.5}, ob1[3] = {ro * c1, ro * s1, -0.5}, ot0[3] = {ro * c0, ro * s0, 0.5}, ot1[3] = {ro * c1, ro * s1, 0.5};
			double ib0[3] = {ri * c0, ri * s0, -0.5}, ib1[3] = {ri * c1, ri * s1, -0.5}, it0[3] = {ri * c0, ri * s0, 0.5}, it1[3] = {ri * c1, ri * s1, 0.5};
			quad(&o, ob0, ob1, ot1, ot0);   // outside wall
			quad(&o, ib1, ib0, it0, it1);   // inside wall, facing in
			quad(&o, ot0, ot1, it1, it0);   // top ring
			quad(&o, ob1, ob0, ib0, ib1);   // bottom ring
		}
	} else if (!strcmp(kind, "torus")) {
		int ns = SIDES, nr = 16;
		double R = 0.375, r = 0.125;   // fills the unit square across; its own height stretches to fill z
		for (int i = 0; i < ns; i++) for (int j = 0; j < nr; j++) {
			double u0 = 2 * M_PI * i / ns, u1 = 2 * M_PI * (i + 1) / ns, v0 = 2 * M_PI * j / nr, v1 = 2 * M_PI * (j + 1) / nr;
			double a[3] = {(R + r * cos(v0)) * cos(u0), (R + r * cos(v0)) * sin(u0), 0.5 * sin(v0)};
			double b[3] = {(R + r * cos(v0)) * cos(u1), (R + r * cos(v0)) * sin(u1), 0.5 * sin(v0)};
			double c[3] = {(R + r * cos(v1)) * cos(u1), (R + r * cos(v1)) * sin(u1), 0.5 * sin(v1)};
			double d[3] = {(R + r * cos(v1)) * cos(u0), (R + r * cos(v1)) * sin(u0), 0.5 * sin(v1)};
			quad(&o, a, b, c, d);
		}
	} else return -1;
	if (o.oom) { free(o.t); return -1; }
	out->tris = o.t; out->count = o.n;
	return 0;
}
