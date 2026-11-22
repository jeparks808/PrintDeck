#ifndef PDPARTS_H
#define PDPARTS_H
#include "PDCSG.h"

// The Design page's Library: shapes made from parameters. Each returns a closed, outward-facing mesh in mm,
// centred on the z axis and standing on z = 0 (out->tris malloc'd; free it). 0 on success, -1 on bad input or
// out of memory. Parts that are combined from pieces (a bolt's head and shaft, a nut's threaded hole, a
// socket recess) run PDCSGCombine, so they take a moment for big threads: call them off the main thread.
//
// Threads are ISO metric 60° threads (right-handed): `clearance` (mm, per side) shrinks an outside thread and
// grows an inside one so printed parts fit (0.15-0.25 for FDM).

// Metric sizes M2 … M12: index 0 … 8. Pitch, hex across flats, nut height, hex head height, socket head
// diameter/height/key, countersunk head diameter. NULL past the end.
typedef struct { const char *name; float d, pitch, hexAF, nutH, hexHeadH, capD, capH, keyAF, cskD; } PDMetric;
const PDMetric *PDMetricSize(int index);
int PDMetricCount(void);

enum { PDHeadHex = 0, PDHeadSocket = 1, PDHeadCountersunk = 2, PDHeadNone = 3 };
enum { PDEdgeNone = 0, PDEdgeFillet = 1, PDEdgeChamfer = 2 };
enum { PDScrewHoleCountersink = 0, PDScrewHoleCounterbore = 1, PDScrewHolePlain = 2 };

// A bolt standing on its head (head at the bottom, so it prints head down). length: the shaft below the head.
int PDPartBolt(int size, float length, int head, int threaded, float clearance, PDCSGMesh *out);
// A hex nut, threaded or with a plain clearance hole.
int PDPartNut(int size, float height, int threaded, float clearance, PDCSGMesh *out);
// A hole shape that cuts an inside thread (group it with the part to tap). depth along z.
int PDPartThreadedHole(int size, float depth, float clearance, PDCSGMesh *out);
// A hole for a screw: clearance diameter all the way, countersink / counterbore at the top (z = depth).
int PDPartScrewHole(int size, float depth, int style, PDCSGMesh *out);
// A round hole with a rounded or chamfered rim at the top (and the bottom too when bothEnds).
int PDPartEdgeHole(float diameter, float depth, int edge, float edgeSize, int bothEnds, PDCSGMesh *out);
// A box with every edge rounded (fillet) or bevelled (chamfer) by `radius`.
int PDPartRoundedBox(float w, float d, float h, float radius, int edge, PDCSGMesh *out);
// A cylinder with its top and bottom rims rounded or bevelled.
int PDPartRoundedCylinder(float diameter, float h, int topEdge, float topSize, int bottomEdge, float bottomSize, PDCSGMesh *out);
// An involute spur gear (20° pressure angle) with an optional bore.
int PDPartGear(int teeth, float module, float thickness, float bore, PDCSGMesh *out);

// The Design page's basic shapes with their options (size in mm, standing on z = 0). sides < 3: smooth round.
enum { PDBoxAllEdges = 0, PDBoxTopAndSides = 1, PDBoxSideEdges = 2 };
// which: all 12 edges, all but the bottom four (prints flat), or just the four upright ones.
int PDShapeBox(float w, float d, float h, int edge, float radius, int which, PDCSGMesh *out);
int PDShapeCylinder(float diameter, float h, int sides, int topEdge, float topSize, int bottomEdge, float bottomSize, PDCSGMesh *out);
int PDShapeCone(float diameter, float topDiameter, float h, int sides, PDCSGMesh *out);   // topDiameter > 0: a frustum
int PDShapeTube(float diameter, float h, float wall, int sides, int edge, float edgeSize, int bothEnds, PDCSGMesh *out);
int PDShapePyramid(float diameter, float h, int sides, PDCSGMesh *out);
int PDShapeSphere(float diameter, int segments, int dome, PDCSGMesh *out);
int PDShapeTorus(float diameter, float tube, int sides, int tubeSides, PDCSGMesh *out);

#endif
