/** Copyright (C) 2013 David Braam - Released under terms of the AGPLv3 License */
#ifndef INFILL_H
#define INFILL_H

#include "utils/polygon.h"

namespace cura {

void generateConcentricInfill(Polygons outline, Polygons& result, int inset_value);
void generateAutomaticInfill(const Polygons& in_outline, Polygons& result, int extrusionWidth, int lineSpacing, int infillOverlap, double rotation);
void generateGridInfill(const Polygons& in_outline, Polygons& result, int extrusionWidth, int lineSpacing, int infillOverlap, double rotation);
// PrintDeck: gyroid. `result` gets open polylines (print them with GCodePlanner::addPolyLinesByOptimizer).
void generateGyroidInfill(const Polygons& in_outline, Polygons& result, int extrusionWidth, int lineSpacing, int infillOverlap, int z);
void generateLineInfill(const Polygons& in_outline, Polygons& result, int extrusionWidth, int lineSpacing, int infillOverlap, double rotation);

}//namespace cura

#endif//INFILL_H
