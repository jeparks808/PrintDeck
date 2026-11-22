#import <Foundation/Foundation.h>

// A print job's toolpath, cut down to what a line render needs on an iPad 1. The G-code is streamed straight
// from the printer (its port-80 web server shares /local/), parsed in C on a background thread, and only the
// visible-surface extrusions are kept (outer/overhang walls, skirt, brim; every extrusion if the file has no
// ;TYPE: comments). Consecutive moves are merged into segments of at least `minLen` mm; when more than
// PDToolpathMaxSegments pile up, the whole path is decimated (minLen doubles), so a 15 MB file still ends up
// at ~1.5 MB of segments. Each loader slot caches its current result on disk (see PDToolpathLoader).
//
// Units: segments are int16 in 0.01 mm (the bed is 256 mm, so 25600 fits), 6 per segment (x0 y0 z0 x1 y1 z1),
// in file order, grouped by layer: layer i owns segments [layerStart[i], layerStart[i+1]).

extern NSString *const PDToolpathNotification;   // loader state changed (progress, done, error)

#define PDToolpathMaxSegments 110000

// Feature ("line type") of each segment, from the ;TYPE: comments; colours as in OrcaSlicer's legend.
typedef enum {
	PDLineOther, PDLineOuterWall, PDLineInnerWall, PDLineOverhang, PDLineSparseInfill, PDLineSolidInfill,
	PDLineTopSurface, PDLineBridge, PDLineGapFill, PDLineSkirt, PDLineSupport, PDLineSupportInterface, PDLineTypeCount
} PDLineType;

@interface PDToolpath : NSObject
@property (nonatomic, readonly, copy) NSString *path;          // "/local/…gcode"
@property (nonatomic, readonly) NSUInteger segmentCount, layerCount;
@property (nonatomic, readonly) const int16_t *segments;
@property (nonatomic, readonly) const uint32_t *layerStart;    // layerCount + 1 entries
@property (nonatomic, readonly) const float *layerZ;           // mm, layerCount entries
@property (nonatomic, readonly) float minX, minY, maxX, maxY, maxZ; // mm, of the kept segments
@property (nonatomic, readonly) float minLen;                  // mm, the merge length it ended up with
@property (nonatomic, readonly) long long fileBytes;
// Per segment: the PDLineType in the low 4 bits, the filament (tool, from T<n>) in the high 4 bits.
@property (nonatomic, readonly) const uint8_t *lineTypes;
// The file's filament colours ("; filament_colour = #RRGGBB;#RRGGBB;…", which ElegooSlicer, Orca and PrintDeck
// write; one per filament, so a CANVAS multi-colour file has up to 4). filamentColor is the first.
@property (nonatomic, readonly) BOOL hasFilamentColor;
@property (nonatomic, readonly) uint32_t filamentColor;        // 0xRRGGBB
@property (nonatomic, readonly) NSUInteger filamentColorCount;   // at most 8
@property (nonatomic, readonly) const uint32_t *filamentColors;   // 0xRRGGBB each, for T0, T1, …
// Parse a local G-code file synchronously (off the main thread). `path` is what .path reports. allTypes keeps
// every extrusion (walls, infill, skin, support) except the start/end ";TYPE:Custom" block: the slicer's preview.
+ (PDToolpath *)toolpathFromFile:(NSString *)file path:(NSString *)path allTypes:(BOOL)all;
@end

// One loader per viewer ("slot"): "job" (the Print job page: the running or last job) and "files" (the Files
// card: the last file picked there). Each slot keeps exactly one parsed toolpath on disk — the one it shows —
// in Library/Caches/toolpaths/<slot>.tp; loading another file replaces (deletes) it. A slot reuses the other
// slot's cache when both show the same file. The raw G-code is never stored.
@interface PDToolpathLoader : NSObject
+ (PDToolpathLoader *)loaderForSlot:(NSString *)slot;   // "job" or "files"
+ (PDToolpathLoader *)shared;                            // the "job" slot
@property (nonatomic, readonly, copy) NSString *slot;
// Loads `path` (printer path) from `url`. `size` is the file size from the printer's file list (0 = unknown),
// used to validate the cache. No-op if that path is already loaded or loading.
- (void)loadPath:(NSString *)path url:(NSURL *)url size:(long long)size;
- (void)reload;                                                // drop the cache for the current path and fetch again
@property (nonatomic, readonly, strong) PDToolpath *toolpath;  // the last finished one (may be for another path)
@property (nonatomic, readonly, copy) NSString *loadingPath;   // nil when idle
@property (nonatomic, readonly) double progress;               // 0..1 while loading
@property (nonatomic, readonly, copy) NSString *error;         // last failure, for loadingPath / the requested path
@property (nonatomic, readonly, copy) NSString *requestedPath;
@end
