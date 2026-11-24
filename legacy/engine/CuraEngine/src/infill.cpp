/** Copyright (C) 2013 David Braam - Released under terms of the AGPLv3 License */
#include "infill.h"
#include <math.h>

namespace cura {

void generateConcentricInfill(Polygons outline, Polygons& result, int inset_value)
{
    while(outline.size() > 0)
    {
        for (unsigned int polyNr = 0; polyNr < outline.size(); polyNr++)
        {
            PolygonRef r = outline[polyNr];
            result.add(r);
        }
        outline = outline.offset(-inset_value);
    }
}

void generateAutomaticInfill(const Polygons& in_outline, Polygons& result,
                             int extrusionWidth, int lineSpacing,
                             int infillOverlap, double rotation)
{
    if (lineSpacing > extrusionWidth * 4)
    {
        generateGridInfill(in_outline, result, extrusionWidth, lineSpacing,
                           infillOverlap, rotation);
    }
    else
    {
        generateLineInfill(in_outline, result, extrusionWidth, lineSpacing,
                           infillOverlap, rotation);
    }
}

void generateGridInfill(const Polygons& in_outline, Polygons& result,
                        int extrusionWidth, int lineSpacing, int infillOverlap,
                        double rotation)
{
    generateLineInfill(in_outline, result, extrusionWidth, lineSpacing * 2,
                       infillOverlap, rotation);
    generateLineInfill(in_outline, result, extrusionWidth, lineSpacing * 2,
                       infillOverlap, rotation + 90);
}

int compare_int64_t(const void* a, const void* b)
{
    int64_t n = (*(int64_t*)a) - (*(int64_t*)b);
    if (n < 0) return -1;
    if (n > 0) return 1;
    return 0;
}

void generateLineInfill(const Polygons& in_outline, Polygons& result, int extrusionWidth, int lineSpacing, int infillOverlap, double rotation)
{
    Polygons outline = in_outline.offset(extrusionWidth * infillOverlap / 100);
    PointMatrix matrix(rotation);
    
    outline.applyMatrix(matrix);
    
    AABB boundary(outline);
    
    boundary.min.X = ((boundary.min.X / lineSpacing) - 1) * lineSpacing;
    int lineCount = (boundary.max.X - boundary.min.X + (lineSpacing - 1)) / lineSpacing;
    vector<vector<int64_t> > cutList;
    for(int n=0; n<lineCount; n++)
        cutList.push_back(vector<int64_t>());

    for(unsigned int polyNr=0; polyNr < outline.size(); polyNr++)
    {
        Point p1 = outline[polyNr][outline[polyNr].size()-1];
        for(unsigned int i=0; i < outline[polyNr].size(); i++)
        {
            Point p0 = outline[polyNr][i];
            int idx0 = (p0.X - boundary.min.X) / lineSpacing;
            int idx1 = (p1.X - boundary.min.X) / lineSpacing;
            int64_t xMin = p0.X, xMax = p1.X;
            if (p0.X > p1.X) { xMin = p1.X; xMax = p0.X; }
            if (idx0 > idx1) { int tmp = idx0; idx0 = idx1; idx1 = tmp; }
            for(int idx = idx0; idx<=idx1; idx++)
            {
                int x = (idx * lineSpacing) + boundary.min.X + lineSpacing / 2;
                if (x < xMin) continue;
                if (x >= xMax) continue;
                int y = p0.Y + (p1.Y - p0.Y) * (x - p0.X) / (p1.X - p0.X);
                cutList[idx].push_back(y);
            }
            p1 = p0;
        }
    }
    
    int idx = 0;
    for(int64_t x = boundary.min.X + lineSpacing / 2; x < boundary.max.X; x += lineSpacing)
    {
        qsort(cutList[idx].data(), cutList[idx].size(), sizeof(int64_t), compare_int64_t);
        for(unsigned int i = 0; i + 1 < cutList[idx].size(); i+=2)
        {
            if (cutList[idx][i+1] - cutList[idx][i] < extrusionWidth / 5)
                continue;
            PolygonRef p = result.newPoly();
            p.add(matrix.unapply(Point(x, cutList[idx][i])));
            p.add(matrix.unapply(Point(x, cutList[idx][i+1])));
        }
        idx += 1;
    }
}

// PrintDeck: gyroid infill. The gyroid sin x cos y + sin y cos z + sin z cos x = 0, cut at the layer height z,
// is a set of curves we can write in closed form. With A = sin x, B = cos z, C = -sin z cos x the cut is
// A cos y + B sin y = C, i.e. R cos(y - phi) = C with R = sqrt(A^2 + B^2), phi = atan2(B, A). When |cos z| >= |sin z|
// then |C| <= R for every x, so the cut is two families of graphs y(x) = phi(x) +- acos(C/R) (+ 2 pi k), each
// continuous. Otherwise the same holds with x and y swapped: x(y) = psi(y) +- acos(D/R') with D = -sin y cos z,
// R' = sqrt(cos^2 y + sin^2 z), psi = atan(cos y / sin z) (+ pi when sin z < 0, which keeps it continuous).
// The period is 2.41 x the line spacing: two curves per period, about 20 % longer than straight lines, so the
// density matches the lines pattern at the same infill %. The curves are sampled, then clipped to the area.
void generateGyroidInfill(const Polygons& in_outline, Polygons& result, int extrusionWidth, int lineSpacing, int infillOverlap, int z)
{
    Polygons outline = in_outline.offset(extrusionWidth * infillOverlap / 100);
    if (outline.size() < 1 || lineSpacing <= 0)
        return;
    AABB box(outline);
    const double pitch = lineSpacing * 2.41;
    const double k = 2.0 * M_PI / pitch;          // radians per micron
    const double zr = z * k;
    const double sz = sin(zr), cz = cos(zr);
    const bool graphsOfX = fabs(cz) >= fabs(sz);
    // Sample along the curve's free axis; finer for small pitches, never finer than a line width.
    double step = pitch / 24.0;
    if (step < extrusionWidth) step = extrusionWidth;
    const int64_t a0 = graphsOfX ? box.min.X : box.min.Y, a1 = graphsOfX ? box.max.X : box.max.Y;   // free axis
    const int64_t b0 = graphsOfX ? box.min.Y : box.min.X, b1 = graphsOfX ? box.max.Y : box.max.X;   // solved axis
    const int kMin = (int)floor(b0 * k / (2 * M_PI)) - 1, kMax = (int)ceil(b1 * k / (2 * M_PI)) + 1;
    Polygons lines;
    for (int branch = -1; branch <= 1; branch += 2)
    {
        for (int kk = kMin; kk <= kMax; kk++)
        {
            PolygonRef line = lines.newPoly();
            for (double a = a0 - step; ; a += step)
            {
                double ar = a * k, br;
                if (graphsOfX)
                {
                    double A = sin(ar), B = cz, C = -sz * cos(ar);
                    double R = sqrt(A * A + B * B);
                    double c = R > 1e-9 ? C / R : 0;
                    if (c > 1) c = 1; if (c < -1) c = -1;
                    br = atan2(B, A) + branch * acos(c) + 2 * M_PI * kk;
                }else
                {
                    double D = -sin(ar) * cz, Rp = sqrt(cos(ar) * cos(ar) + sz * sz);
                    double c = Rp > 1e-9 ? D / Rp : 0;
                    if (c > 1) c = 1; if (c < -1) c = -1;
                    double psi = atan(cos(ar) / sz) + (sz < 0 ? M_PI : 0);
                    br = psi + branch * acos(c) + 2 * M_PI * kk;
                }
                int64_t b = (int64_t)(br / k);
                line.add(graphsOfX ? Point((int64_t)a, b) : Point(b, (int64_t)a));
                if (a > a1 + step)
                    break;
            }
        }
    }
    Polygons clipped = outline.intersectionPolyLines(lines);
    for (unsigned int i = 0; i < clipped.size(); i++)
    {
        PolygonRef l = clipped[i];
        if (l.size() < 2)
            continue;
        int64_t len = 0;
        for (unsigned int j = 1; j < l.size(); j++)
            len += vSize(l[j] - l[j - 1]);
        if (len < extrusionWidth)   // crumbs at the edge
            continue;
        result.add(l);
    }
}

}//namespace cura
