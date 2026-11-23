#include "PDCSG.h"
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

// Boolean operations on closed meshes with BSP trees, after Evan Wallace's csg.js (MIT): every polygon of one
// solid is split by the planes of the other's tree and kept or dropped by which side it lands on.

#define CSG_EPS 1e-5      // mm: a vertex this close to a plane is on it
#define WELD_EPS 2e-4     // mm: output vertices this close are one vertex; one this close to an edge sits on it

typedef struct { double x, y, z; } V;
typedef struct { V n; double w; } Plane;
typedef struct { int n; V *v; Plane pl; } Poly;
typedef struct { Poly *a; int n, cap; } PList;
typedef struct Node { Plane pl; int has; struct Node *front, *back; PList polys; } Node;
// Progress: the job is a run of operations (each a share of the whole, opBase…opBase + opSpan), each in phases
// (phBase…phBase + phSpan of the operation); a phase counts its work (polygon splits, output polygons) against
// an estimate.
typedef struct {
	int oom;
	PDCSGProgressFn fn; void *user;
	double opBase, opSpan, phBase, phSpan, work, expect;
	int step, steps, ticks;
	float last; int lastStep;
} Ctx;

static void report(Ctx *c, int force) {
	if (!c->fn) return;
	double k = c->expect > 0 ? c->work / c->expect : 0;
	if (k > 0.97) k = 0.97;
	float f = (float)(c->opBase + c->opSpan * (c->phBase + c->phSpan * k));
	if (f > 1) f = 1;
	if (f < c->last) f = c->last;
	if (!force && f - c->last < 0.004f && c->step == c->lastStep) return;
	c->last = f; c->lastStep = c->step;
	c->fn(c->user, f, c->step, c->steps);
}
static void tick(Ctx *c) { if (c->fn) { c->work += 1; if ((++c->ticks & 255) == 0) report(c, 0); } }
static void phase(Ctx *c, double base, double span, double expect) {
	c->phBase = base; c->phSpan = span; c->work = 0; c->expect = expect > 1 ? expect : 1;
	report(c, 0);
}
static double est(double n) { return n * (n > 2 ? log2(n) : 1); }   // splits to build a tree of n polygons

static V vsub(V a, V b) { V r = {a.x - b.x, a.y - b.y, a.z - b.z}; return r; }
static double vdot(V a, V b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static V vcross(V a, V b) { V r = {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; return r; }
static V vlerp(V a, V b, double t) { V r = {a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t}; return r; }

#pragma mark - Polygon lists

static void poly_free(Poly *p) { free(p->v); p->v = NULL; p->n = 0; }

static void plist_free(PList *l) {
	for (int i = 0; i < l->n; i++) poly_free(&l->a[i]);
	free(l->a);
	l->a = NULL; l->n = l->cap = 0;
}

// Moves p into l (l owns its vertices from now on); frees them if l can't grow.
static void plist_push(Ctx *c, PList *l, Poly p) {
	if (l->n == l->cap) {
		int cap = l->cap ? l->cap * 2 : 16;
		Poly *a = realloc(l->a, (size_t)cap * sizeof(Poly));
		if (!a) { c->oom = 1; poly_free(&p); return; }
		l->a = a; l->cap = cap;
	}
	l->a[l->n++] = p;
}

static void plist_append(Ctx *c, PList *to, PList *from) {   // moves every polygon of from
	for (int i = 0; i < from->n; i++) plist_push(c, to, from->a[i]);
	free(from->a);
	from->a = NULL; from->n = from->cap = 0;
}

static int poly_make(Ctx *c, Poly *p, const V *v, int n, const Plane *pl) {
	p->v = malloc((size_t)n * sizeof(V));
	if (!p->v) { c->oom = 1; p->n = 0; return 0; }
	memcpy(p->v, v, (size_t)n * sizeof(V));
	p->n = n;
	p->pl = *pl;
	return 1;
}

static void poly_flip(Poly *p) {
	for (int i = 0, j = p->n - 1; i < j; i++, j--) { V t = p->v[i]; p->v[i] = p->v[j]; p->v[j] = t; }
	p->pl.n.x = -p->pl.n.x; p->pl.n.y = -p->pl.n.y; p->pl.n.z = -p->pl.n.z; p->pl.w = -p->pl.w;
}

// Triangles -> polygons (degenerate ones dropped).
static void plist_from_mesh(Ctx *c, PList *l, const PDCSGMesh *m) {
	for (int i = 0; i < m->count; i++) {
		const float *t = m->tris + i * 9;
		V v[3] = {{t[0], t[1], t[2]}, {t[3], t[4], t[5]}, {t[6], t[7], t[8]}};
		V n = vcross(vsub(v[1], v[0]), vsub(v[2], v[0]));
		double len = sqrt(vdot(n, n));
		if (len < 1e-12) continue;
		Plane pl = {{n.x / len, n.y / len, n.z / len}, 0};
		pl.w = vdot(pl.n, v[0]);
		Poly p;
		if (poly_make(c, &p, v, 3, &pl)) plist_push(c, l, p);
	}
}

static void plist_bounds(const PList *l, V *lo, V *hi) {
	lo->x = lo->y = lo->z = 1e30; hi->x = hi->y = hi->z = -1e30;
	for (int i = 0; i < l->n; i++) for (int k = 0; k < l->a[i].n; k++) {
		V p = l->a[i].v[k];
		if (p.x < lo->x) lo->x = p.x; if (p.y < lo->y) lo->y = p.y; if (p.z < lo->z) lo->z = p.z;
		if (p.x > hi->x) hi->x = p.x; if (p.y > hi->y) hi->y = p.y; if (p.z > hi->z) hi->z = p.z;
	}
}

static int boxes_overlap(const PList *a, const PList *b) {
	V alo, ahi, blo, bhi;
	plist_bounds(a, &alo, &ahi); plist_bounds(b, &blo, &bhi);
	double e = 1e-3;
	return alo.x <= bhi.x + e && blo.x <= ahi.x + e && alo.y <= bhi.y + e && blo.y <= ahi.y + e && alo.z <= bhi.z + e && blo.z <= ahi.z + e;
}

#pragma mark - BSP

enum { COPLANAR = 0, FRONT = 1, BACK = 2, SPANNING = 3 };

// Moves p into one of the four lists, split in two if the plane crosses it.
static void split(Ctx *c, const Plane *pl, Poly p, PList *cf, PList *cb, PList *f, PList *b) {
	int type = 0, n = p.n;
	tick(c);
	int stackTypes[16], *types = n <= 16 ? stackTypes : malloc((size_t)n * sizeof(int));
	if (!types) { c->oom = 1; poly_free(&p); return; }
	for (int i = 0; i < n; i++) {
		double t = vdot(pl->n, p.v[i]) - pl->w;
		int ty = t < -CSG_EPS ? BACK : t > CSG_EPS ? FRONT : COPLANAR;
		type |= ty;
		types[i] = ty;
	}
	if (type == COPLANAR) plist_push(c, vdot(pl->n, p.pl.n) > 0 ? cf : cb, p);
	else if (type == FRONT) plist_push(c, f, p);
	else if (type == BACK) plist_push(c, b, p);
	else {
		V *fv = malloc((size_t)(n + 2) * sizeof(V)), *bv = malloc((size_t)(n + 2) * sizeof(V));
		int nf = 0, nb = 0;
		if (!fv || !bv) { c->oom = 1; free(fv); free(bv); poly_free(&p); if (types != stackTypes) free(types); return; }
		for (int i = 0; i < n; i++) {
			int j = (i + 1) % n, ti = types[i], tj = types[j];
			V vi = p.v[i], vj = p.v[j];
			if (ti != BACK) fv[nf++] = vi;
			if (ti != FRONT) bv[nb++] = vi;
			if ((ti | tj) == SPANNING) {
				double t = (pl->w - vdot(pl->n, vi)) / vdot(pl->n, vsub(vj, vi));
				V v = vlerp(vi, vj, t);
				fv[nf++] = v; bv[nb++] = v;
			}
		}
		Poly q;
		if (nf >= 3 && poly_make(c, &q, fv, nf, &p.pl)) plist_push(c, f, q);
		if (nb >= 3 && poly_make(c, &q, bv, nb, &p.pl)) plist_push(c, b, q);
		free(fv); free(bv);
		poly_free(&p);
	}
	if (types != stackTypes) free(types);
}

static Node *node_new(Ctx *c) {
	Node *n = calloc(1, sizeof(Node));
	if (!n) c->oom = 1;
	return n;
}

static void node_free(Node *n) {
	if (!n) return;
	node_free(n->front); node_free(n->back);
	plist_free(&n->polys);
	free(n);
}

// Adds the polygons of in (consumed) to the tree.
static void build(Ctx *c, Node *nd, PList *in) {
	if (!in->n) { plist_free(in); return; }
	if (!nd->has) {
		// The splitting plane: of a dozen candidates, the one that cuts the fewest polygons (judged on a sample)
		// and divides the rest most evenly. Taking just the first polygon's plane, as csg.js does, shatters
		// curved meshes such as threads into ten times as many pieces.
		int best = 0;
		if (in->n > 8) {
			int cands = in->n < 12 ? in->n : 12, stride = in->n > 240 ? in->n / 240 : 1;
			long bestScore = -1;
			for (int k = 0; k < cands; k++) {
				int ci = (int)((long)k * in->n / cands);
				const Plane *pl = &in->a[ci].pl;
				long spans = 0, fr = 0, bk = 0;
				for (int i = 0; i < in->n; i += stride) {
					const Poly *p = &in->a[i];
					int type = 0;
					for (int v = 0; v < p->n; v++) {
						double t = vdot(pl->n, p->v[v]) - pl->w;
						type |= t < -CSG_EPS ? BACK : t > CSG_EPS ? FRONT : COPLANAR;
					}
					if (type == SPANNING) spans++; else if (type == FRONT) fr++; else if (type == BACK) bk++;
				}
				long score = spans * 6 + (fr > bk ? fr - bk : bk - fr);
				if (bestScore < 0 || score < bestScore) { bestScore = score; best = ci; }
			}
		}
		nd->pl = in->a[best].pl; nd->has = 1;
	}
	PList f = {0}, b = {0};
	for (int i = 0; i < in->n; i++) split(c, &nd->pl, in->a[i], &nd->polys, &nd->polys, &f, &b);
	free(in->a); in->a = NULL; in->n = in->cap = 0;
	if (f.n) { if (!nd->front) nd->front = node_new(c); if (nd->front) build(c, nd->front, &f); else plist_free(&f); }
	if (b.n) { if (!nd->back) nd->back = node_new(c); if (nd->back) build(c, nd->back, &b); else plist_free(&b); }
}

// The polygons of in (consumed) that lie outside the solid of this tree.
static PList clip(Ctx *c, Node *nd, PList in) {
	if (!nd->has) return in;
	PList f = {0}, b = {0};
	for (int i = 0; i < in.n; i++) split(c, &nd->pl, in.a[i], &f, &b, &f, &b);
	free(in.a);
	if (nd->front) f = clip(c, nd->front, f);
	if (nd->back) b = clip(c, nd->back, b); else plist_free(&b);
	plist_append(c, &f, &b);
	return f;
}

static void clip_to(Ctx *c, Node *a, Node *b) {   // removes a's polygons inside b
	if (!a) return;
	a->polys = clip(c, b, a->polys);
	clip_to(c, a->front, b);
	clip_to(c, a->back, b);
}

static void invert(Node *nd) {   // solid <-> space
	if (!nd) return;
	for (int i = 0; i < nd->polys.n; i++) poly_flip(&nd->polys.a[i]);
	nd->pl.n.x = -nd->pl.n.x; nd->pl.n.y = -nd->pl.n.y; nd->pl.n.z = -nd->pl.n.z; nd->pl.w = -nd->pl.w;
	invert(nd->front); invert(nd->back);
	Node *t = nd->front; nd->front = nd->back; nd->back = t;
}

static void take_all(Ctx *c, Node *nd, PList *out) {   // moves every polygon out of the tree
	if (!nd) return;
	plist_append(c, out, &nd->polys);
	take_all(c, nd->front, out);
	take_all(c, nd->back, out);
}

static Node *tree(Ctx *c, PList *l) {
	Node *n = node_new(c);
	if (n) build(c, n, l); else plist_free(l);
	return n;
}

// a ∪ b and a − b (both consumed).
static PList op_union(Ctx *c, PList a, PList b) {
	if (!a.n || !b.n || !boxes_overlap(&a, &b)) { plist_append(c, &a, &b); return a; }   // apart: both, as they are
	double na = a.n, nb = b.n, la = na > 2 ? log2(na) : 1, lb = nb > 2 ? log2(nb) : 1;
	phase(c, 0, 0.2, est(na));
	Node *A = tree(c, &a);
	phase(c, 0.2, 0.2, est(nb));
	Node *B = tree(c, &b);
	PList out = {0};
	if (A && B) {
		phase(c, 0.4, 0.12, na * lb * 1.5); clip_to(c, A, B);
		phase(c, 0.52, 0.12, nb * la * 1.5); clip_to(c, B, A);
		phase(c, 0.64, 0.12, nb * la * 1.5); invert(B); clip_to(c, B, A); invert(B);
		PList bp = {0}; take_all(c, B, &bp);
		phase(c, 0.76, 0.2, est(bp.n)); build(c, A, &bp);
		phase(c, 0.96, 0.04, 1);
		take_all(c, A, &out);
	}
	node_free(A); node_free(B);
	return out;
}

static PList op_subtract(Ctx *c, PList a, PList b) {
	if (!a.n || !b.n || !boxes_overlap(&a, &b)) { plist_free(&b); return a; }   // nothing to cut
	double na = a.n, nb = b.n, la = na > 2 ? log2(na) : 1, lb = nb > 2 ? log2(nb) : 1;
	phase(c, 0, 0.2, est(na));
	Node *A = tree(c, &a);
	phase(c, 0.2, 0.2, est(nb));
	Node *B = tree(c, &b);
	PList out = {0};
	if (A && B) {
		phase(c, 0.4, 0.12, na * lb * 1.5); invert(A); clip_to(c, A, B);
		phase(c, 0.52, 0.12, nb * la * 1.5); clip_to(c, B, A);
		phase(c, 0.64, 0.12, nb * la * 1.5); invert(B); clip_to(c, B, A); invert(B);
		PList bp = {0}; take_all(c, B, &bp);
		phase(c, 0.76, 0.2, est(bp.n)); build(c, A, &bp); invert(A);
		phase(c, 0.96, 0.04, 1);
		take_all(c, A, &out);
	}
	node_free(A); node_free(B);
	return out;
}

#pragma mark - Output: weld, mend T-junctions, triangulate

typedef struct { V *v; int n, cap; int *cell, *next; double cs; V lo; int gx, gy, gz; int *head; } Verts;

static int cell_of(const Verts *vs, double x, double y, double z, int *ix, int *iy, int *iz) {
	*ix = (int)floor((x - vs->lo.x) / vs->cs); *iy = (int)floor((y - vs->lo.y) / vs->cs); *iz = (int)floor((z - vs->lo.z) / vs->cs);
	if (*ix < 0) *ix = 0; if (*iy < 0) *iy = 0; if (*iz < 0) *iz = 0;
	if (*ix >= vs->gx) *ix = vs->gx - 1; if (*iy >= vs->gy) *iy = vs->gy - 1; if (*iz >= vs->gz) *iz = vs->gz - 1;
	return (*iz * vs->gy + *iy) * vs->gx + *ix;
}

// Cell lists hold (vertex, next) entries; a vertex is listed in every cell within WELD_EPS of it.
typedef struct { int *vert, *next, n, cap; } Links;

static int links_add(Links *L, int *head, int cell, int vid) {
	if (L->n == L->cap) {
		int cap = L->cap ? L->cap * 2 : 1024;
		int *a = realloc(L->vert, (size_t)cap * sizeof(int)), *b;
		if (!a) return 0;
		L->vert = a;
		b = realloc(L->next, (size_t)cap * sizeof(int));
		if (!b) return 0;
		L->next = b; L->cap = cap;
	}
	L->vert[L->n] = vid; L->next[L->n] = head[cell]; head[cell] = L->n++;
	return 1;
}

typedef struct { double t; int v; } EdgePt;
static int cmp_edgept(const void *a, const void *b) { double d = ((const EdgePt *)a)->t - ((const EdgePt *)b)->t; return d < 0 ? -1 : d > 0; }

static int emit_tri(float **out, int *n, int *cap, V a, V b, V c) {
	V nrm = vcross(vsub(b, a), vsub(c, a));
	if (vdot(nrm, nrm) < 1e-18) return 1;   // no area
	if (*n == *cap) {
		int nc = *cap ? *cap * 2 : 256;
		float *t = realloc(*out, (size_t)nc * 9 * sizeof(float));
		if (!t) return 0;
		*out = t; *cap = nc;
	}
	float *t = *out + (size_t)*n * 9;
	t[0] = (float)a.x; t[1] = (float)a.y; t[2] = (float)a.z; t[3] = (float)b.x; t[4] = (float)b.y; t[5] = (float)b.z;
	t[6] = (float)c.x; t[7] = (float)c.y; t[8] = (float)c.z;
	(*n)++;
	return 1;
}

static int to_mesh(Ctx *c, PList *l, PDCSGMesh *out) {
	out->tris = NULL; out->count = 0;
	int total = 0;
	for (int i = 0; i < l->n; i++) total += l->a[i].n;
	if (!total) return 0;
	V lo, hi;
	plist_bounds(l, &lo, &hi);
	double ext = fmax(hi.x - lo.x, fmax(hi.y - lo.y, hi.z - lo.z));
	Verts vs = {0};
	vs.lo = lo; vs.cs = fmax(ext / 48.0, 0.05);
	vs.gx = (int)((hi.x - lo.x) / vs.cs) + 1; vs.gy = (int)((hi.y - lo.y) / vs.cs) + 1; vs.gz = (int)((hi.z - lo.z) / vs.cs) + 1;
	int cells = vs.gx * vs.gy * vs.gz;
	int *head = malloc((size_t)cells * sizeof(int));
	V *pts = malloc((size_t)total * sizeof(V));
	int *idx = malloc((size_t)total * sizeof(int));   // per polygon corner: its welded vertex
	Links L = {0};
	int ok = head && pts && idx, np = 0;
	if (ok) for (int i = 0; i < cells; i++) head[i] = -1;
	// Weld.
	for (int i = 0, k = 0; ok && i < l->n; i++) for (int j = 0; j < l->a[i].n; j++, k++) {
		if (!j) tick(c);
		V p = l->a[i].v[j];
		int ix, iy, iz, found = -1;
		int cell = cell_of(&vs, p.x, p.y, p.z, &ix, &iy, &iz);
		for (int e = head[cell]; e >= 0 && found < 0; e = L.next[e]) {
			V q = pts[L.vert[e]];
			if (fabs(q.x - p.x) <= WELD_EPS && fabs(q.y - p.y) <= WELD_EPS && fabs(q.z - p.z) <= WELD_EPS) found = L.vert[e];
		}
		if (found < 0) {
			found = np; pts[np++] = p;
			// listed in each cell within WELD_EPS (so lookups from either side of a cell wall find it)
			int x0, y0, z0, x1, y1, z1;
			cell_of(&vs, p.x - WELD_EPS, p.y - WELD_EPS, p.z - WELD_EPS, &x0, &y0, &z0);
			cell_of(&vs, p.x + WELD_EPS, p.y + WELD_EPS, p.z + WELD_EPS, &x1, &y1, &z1);
			for (int z = z0; z <= z1 && ok; z++) for (int y = y0; y <= y1 && ok; y++) for (int x = x0; x <= x1 && ok; x++)
				ok = links_add(&L, head, (z * vs.gy + y) * vs.gx + x, found);
		}
		idx[k] = found;
	}
	// Each polygon: put every vertex lying on one of its edges into that edge, then fan it into triangles.
	float *tris = NULL; int nt = 0, capT = 0;
	EdgePt *ep = NULL; int capE = 0;
	int *ring = NULL; int capR = 0;
	char *seen = ok ? calloc((size_t)np, 1) : NULL;
	int *seenList = ok ? malloc((size_t)np * sizeof(int)) : NULL;
	if (!seen || !seenList) ok = 0;
	for (int i = 0, k0 = 0; ok && i < l->n; k0 += l->a[i].n, i++) {
		Poly *p = &l->a[i];
		int nr = 0, inserted = 0;
		tick(c);
		for (int j = 0; ok && j < p->n; j++) {
			int a = idx[k0 + j], b = idx[k0 + (j + 1) % p->n];
			if (a == b) continue;
			if (nr + 1 > capR) { capR = (nr + 1) * 2 + 16; int *r = realloc(ring, (size_t)capR * sizeof(int)); if (!r) { ok = 0; break; } ring = r; }
			ring[nr++] = a;
			// Cells along the edge (3D DDA), and the vertices in them that sit on it.
			V A = pts[a], B = pts[b], d = vsub(B, A);
			double len2 = vdot(d, d);
			int ne = 0, ns = 0;
			int cx, cy, cz, ex, ey, ez;
			cell_of(&vs, A.x, A.y, A.z, &cx, &cy, &cz);
			cell_of(&vs, B.x, B.y, B.z, &ex, &ey, &ez);
			int sx = d.x > 0 ? 1 : -1, sy = d.y > 0 ? 1 : -1, sz = d.z > 0 ? 1 : -1;
			double tdx = d.x != 0 ? vs.cs / fabs(d.x) : 1e30, tdy = d.y != 0 ? vs.cs / fabs(d.y) : 1e30, tdz = d.z != 0 ? vs.cs / fabs(d.z) : 1e30;
			double bx = vs.lo.x + (cx + (sx > 0)) * vs.cs, by = vs.lo.y + (cy + (sy > 0)) * vs.cs, bz = vs.lo.z + (cz + (sz > 0)) * vs.cs;
			double tmx = d.x != 0 ? (bx - A.x) / d.x : 1e30, tmy = d.y != 0 ? (by - A.y) / d.y : 1e30, tmz = d.z != 0 ? (bz - A.z) / d.z : 1e30;
			for (int guard = 0; guard < vs.gx + vs.gy + vs.gz + 3; guard++) {
				int cell = (cz * vs.gy + cy) * vs.gx + cx;
				for (int e = head[cell]; e >= 0; e = L.next[e]) {
					int v = L.vert[e];
					if (v == a || v == b || seen[v]) continue;
					seen[v] = 1; seenList[ns++] = v;
					V w = vsub(pts[v], A);
					double t = vdot(w, d) / len2;
					if (t <= 0 || t >= 1) continue;
					V off = vsub(w, (V){d.x * t, d.y * t, d.z * t});
					if (vdot(off, off) > WELD_EPS * WELD_EPS) continue;
					if (ne == capE) { capE = capE ? capE * 2 : 16; EdgePt *q = realloc(ep, (size_t)capE * sizeof(EdgePt)); if (!q) { ok = 0; break; } ep = q; }
					ep[ne].t = t; ep[ne].v = v; ne++;
				}
				if (!ok || (cx == ex && cy == ey && cz == ez)) break;
				if (tmx < tmy && tmx < tmz) { if (tmx > 1) break; cx += sx; tmx += tdx; }
				else if (tmy < tmz) { if (tmy > 1) break; cy += sy; tmy += tdy; }
				else { if (tmz > 1) break; cz += sz; tmz += tdz; }
				if (cx < 0 || cy < 0 || cz < 0 || cx >= vs.gx || cy >= vs.gy || cz >= vs.gz) break;
			}
			for (int s = 0; s < ns; s++) seen[seenList[s]] = 0;
			if (ne > 1) qsort(ep, (size_t)ne, sizeof(EdgePt), cmp_edgept);
			if (nr + ne > capR) { capR = (nr + ne) * 2 + 16; int *r = realloc(ring, (size_t)capR * sizeof(int)); if (!r) { ok = 0; break; } ring = r; }
			for (int s = 0; s < ne; s++) if (ring[nr - 1] != ep[s].v) ring[nr++] = ep[s].v;
			inserted += ne;
		}
		if (!ok || nr < 3) continue;
		if (!inserted) {   // convex, corners only: a fan from the first
			for (int j = 1; j + 1 < nr && ok; j++) ok = emit_tri(&tris, &nt, &capT, pts[ring[0]], pts[ring[j]], pts[ring[j + 1]]);
		} else {           // with points along its edges: a fan from its centre keeps every edge piece
			V cen = {0, 0, 0};
			for (int j = 0; j < nr; j++) { cen.x += pts[ring[j]].x; cen.y += pts[ring[j]].y; cen.z += pts[ring[j]].z; }
			cen.x /= nr; cen.y /= nr; cen.z /= nr;
			for (int j = 0; j < nr && ok; j++) ok = emit_tri(&tris, &nt, &capT, cen, pts[ring[j]], pts[ring[(j + 1) % nr]]);
		}
	}
	free(ep); free(ring); free(seen); free(seenList);
	free(head); free(pts); free(idx); free(L.vert); free(L.next);
	if (!ok) { free(tris); return -1; }
	out->tris = tris; out->count = nt;
	return 0;
}

#pragma mark - Entry

typedef struct {
	const PDCSGMesh *solids, *holes; int ns, nh;
	PDCSGMesh *out; int result;
	PDCSGProgressFn fn; void *user;
} Job;

static void *run(void *arg) {
	Job *j = arg;
	Ctx c = {0};
	c.fn = j->fn; c.user = j->user;
	// Each operation's share of the whole, by how many triangles it takes in: merging the k-th solid works on
	// everything merged so far; cutting works on all of it; the output pass is lighter.
	double totS = 0, totH = 0, W = 0;
	for (int i = 0; i < j->ns; i++) totS += j->solids[i].count;
	for (int i = 0; i < j->nh; i++) totH += j->holes[i].count;
	double cum = j->ns ? j->solids[0].count : 0;
	for (int i = 1; i < j->ns; i++) { cum += j->solids[i].count; W += cum; c.steps++; }
	cum = j->nh ? j->holes[0].count : 0;
	for (int i = 1; i < j->nh; i++) { cum += j->holes[i].count; W += cum; c.steps++; }
	if (j->ns && j->nh) { W += 1.5 * (totS + totH); c.steps++; }
	double wOut = 0.3 * (totS + totH) + 1;
	W += wOut; c.steps++;
	#define BEGIN(w) do { c.opBase += c.opSpan; c.opSpan = (w) / W; c.step++; phase(&c, 0, 1, 1); } while (0)
	PList acc = {0}, cut = {0};
	cum = 0;
	for (int i = 0; i < j->ns && !c.oom; i++) {
		cum += j->solids[i].count;
		if (i) BEGIN(cum);
		PList m = {0}; plist_from_mesh(&c, &m, &j->solids[i]); acc = op_union(&c, acc, m);
	}
	cum = 0;
	for (int i = 0; i < j->nh && !c.oom; i++) {
		cum += j->holes[i].count;
		if (i) BEGIN(cum);
		PList m = {0}; plist_from_mesh(&c, &m, &j->holes[i]); cut = op_union(&c, cut, m);
	}
	if (j->ns && j->nh) BEGIN(1.5 * (totS + totH));
	PList res = j->ns ? op_subtract(&c, acc, cut) : cut;
	BEGIN(wOut);
	phase(&c, 0, 1, 2.0 * res.n);   // weld, then triangulate: a tick per polygon each
	j->result = c.oom ? -1 : to_mesh(&c, &res, j->out);
	#undef BEGIN
	if (c.fn) { c.phBase = 1; c.phSpan = 0; c.opBase = 1; c.opSpan = 0; report(&c, 1); }
	plist_free(&res);
	return NULL;
}

int PDCSGCombine(const PDCSGMesh *solids, int solidCount, const PDCSGMesh *holes, int holeCount, PDCSGMesh *out) {
	return PDCSGCombineProgress(solids, solidCount, holes, holeCount, out, NULL, NULL);
}

int PDCSGCombineProgress(const PDCSGMesh *solids, int solidCount, const PDCSGMesh *holes, int holeCount, PDCSGMesh *out,
		PDCSGProgressFn fn, void *user) {
	Job j = {solids, holes, solidCount, holeCount, out, -1, fn, user};
	out->tris = NULL; out->count = 0;
	pthread_attr_t at;
	pthread_t th;
	pthread_attr_init(&at);
	pthread_attr_setstacksize(&at, 16 << 20);   // deep BSP trees recurse deeply
	if (pthread_create(&th, &at, run, &j) != 0) { pthread_attr_destroy(&at); run(&j); return j.result; }
	pthread_attr_destroy(&at);
	pthread_join(th, NULL);
	return j.result;
}

void PDCSGFree(PDCSGMesh *m) { if (m) { free(m->tris); m->tris = NULL; m->count = 0; } }
