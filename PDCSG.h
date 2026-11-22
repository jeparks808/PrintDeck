#ifndef PDCSG_H
#define PDCSG_H

// Solid modelling for the Design page: closed triangle meshes combined with boolean operations.
//
// PDCSGCombine is what grouping does: the union of every solid, minus the union of every hole. It uses BSP trees
// (the classic "csg.js" method: each mesh clips the other's polygons against its own planes), which needs every
// input to be closed (watertight) and outward-facing, as the Design page's primitives are. The result is
// closed too: polygon edges that end on another polygon's edge (T-junctions, which a slicer would read as gaps)
// are split there before the polygons are fanned into triangles.
//
// Plain C, any thread. The BSP recursion runs on its own thread with a large stack.

typedef struct {
	float *tris;   // 9 floats (3 xyz vertices, counter-clockwise seen from outside) per triangle, mm
	int count;     // triangles
} PDCSGMesh;

// out->tris is malloc'd (free it). Returns 0, or -1 when out of memory. With no solids the result is the union
// of the holes (a group made only of holes is a hole).
int PDCSGCombine(const PDCSGMesh *solids, int solidCount, const PDCSGMesh *holes, int holeCount, PDCSGMesh *out);

void PDCSGFree(PDCSGMesh *m);

#endif
