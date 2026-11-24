#ifndef PDPRIMITIVES_H
#define PDPRIMITIVES_H
#include "PDCSG.h"

// The Design page's basic shapes, each a closed outward-facing mesh filling the unit cube [-0.5, 0.5]³ (z up),
// which a shape's matrix then stretches to its size and places. Kinds, in palette order:
//   box, cylinder, sphere, dome (half sphere, flat side down), cone, pyramid, roof (a ridge along y),
//   wedge (a ramp rising toward -x), tube (a cylinder with a hole, walls a fifth of its width), torus.
// Returns 0 with a malloc'd mesh in out, or -1 for an unknown kind.
int PDPrimitiveMesh(const char *kind, PDCSGMesh *out);

#endif
