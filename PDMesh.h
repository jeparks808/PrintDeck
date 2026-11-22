#import <Foundation/Foundation.h>

// One bed leveling mesh: a grid of probed Z heights (mm) over the bed, plus the bed extents the grid
// spans. Row 0 is the front (min Y); column 0 is the left (min X). Heights are the physical surface the
// probe measured (a few hundredths of a mm), so tramming the bed screws to flatten this is what reduces
// how much the printer's auto-level has to compensate.
@interface PDMesh : NSObject
@property (nonatomic, readonly) NSUInteger nx, ny;          // grid columns, rows
@property (nonatomic, readonly) double minX, minY, maxX, maxY;  // bed area the grid covers, mm
@property (nonatomic, readonly, copy) NSString *profileName;
@property (nonatomic, readonly) double min, max, mean, range;   // over all heights

- (double)zAtCol:(NSUInteger)gx row:(NSUInteger)gy;        // raw grid height, mm
- (double)heightAtX:(double)x y:(double)y;                 // bilinear sample in bed coords (clamped), mm

// Parsers. Return nil on anything unrecognisable.
+ (PDMesh *)meshFromJSON:(NSDictionary *)json;             // our helper/sim format (see toJSON)
+ (PDMesh *)meshFromMoonraker:(NSDictionary *)bedMeshObject;  // Moonraker "bed_mesh" object (COSMOS)
+ (PDMesh *)meshFromKlipperText:(NSString *)text;          // a `[bed_mesh default]` block or BED_MESH_OUTPUT dump

- (NSDictionary *)toJSON;                                   // for caching / the helper contract
@end


// Supplies the current mesh to the view. Priority: a plain-HTTP helper/Moonraker URL, a mesh pasted by
// the user, or the last good mesh cached in NSUserDefaults. All plain HTTP, so iOS 5's old TLS is moot.
extern NSString *const PDMeshDidUpdateNotification;

@interface PDMeshSource : NSObject
+ (PDMeshSource *)shared;
@property (nonatomic, readonly, strong) PDMesh *mesh;      // last good, or nil
@property (nonatomic, readonly, copy) NSString *lastError;
@property (nonatomic, readonly) BOOL fetching;
@property (nonatomic, copy) NSString *helperURL;           // e.g. http://192.168.0.185:7140/mesh ; nil = none

- (void)fetch;                                             // async; posts PDMeshDidUpdateNotification
- (BOOL)setPastedText:(NSString *)text error:(NSString **)err;  // manual paste/load path
- (void)loadDemo;                                          // a synthetic warped mesh, for previewing the view
@end
