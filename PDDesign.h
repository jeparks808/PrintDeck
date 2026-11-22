#import <Foundation/Foundation.h>
#import <GLKit/GLKit.h>

// The Design page's document: shapes on the 256 mm plate, Tinkercad-style.
//
// Every shape is a unit mesh (filling [-0.5, 0.5]³) and a matrix that stretches, turns and places it in mm, with
// z up and the plate at z = 0. A shape is solid or a hole. Holes cut only inside a group: grouping shapes makes
// one shape whose mesh is the union of its solids minus the union of its holes (PDCSG), and keeps the members
// (in the group's unit frame) so it can be ungrouped again. Shapes are immutable apart from matrix, hole and
// colour, and copies share their meshes, so undo keeps whole arrays of copies.

@interface PDShape : NSObject <NSCopying>
+ (NSArray *)kinds;                              // palette order ("box", "cylinder", …, "torus")
+ (NSString *)titleForKind:(NSString *)kind;     // "Box", … "Group"
// A new shape standing on the plate with its footprint centred at (x, y).
+ (PDShape *)shapeOfKind:(NSString *)kind size:(GLKVector3)size x:(float)x y:(float)y;
// A group of the given shapes (world meshes combined with PDCSG; slow for big meshes, so call it off the main
// thread). Nil when the result is empty (holes that cut everything away).
+ (PDShape *)groupOf:(NSArray *)shapes;

@property (nonatomic, readonly, copy) NSString *kind;   // a primitive kind, or "group"
@property (nonatomic, readonly, strong) NSArray *children;   // a group's members (matrices in its unit frame)
@property (nonatomic) BOOL hole;
@property (nonatomic) uint32_t color;            // 0xRRGGBB (solids)
@property (nonatomic) GLKMatrix4 matrix;         // unit mesh -> world, mm

- (NSString *)title;
- (const float *)unitTriangles:(int *)count;     // the shape's own mesh (9 floats per triangle)
- (id)meshObject;                                // identifies the mesh (copies share it)
- (float *)newWorldTriangles:(int *)count;       // malloc'd, in mm (free it)
- (GLKVector3)worldMin;                          // world bounding box (from the mesh)
- (GLKVector3)worldMax;
- (GLKVector3)axisLengths;                       // its size along its own axes (W, D, H), mm
// Its turn from its own original axes, as angles about X, then Y, then Z (degrees, -180…180); mirroring ignored.
- (GLKVector3)rotationDegrees;
// "X 0°  Y 0°  Z 45°" for the shapes (the same turn for all), or "mixed" when they differ.
+ (NSString *)rotationTextFor:(NSArray *)shapes;
- (NSArray *)ungrouped;                          // a group's members placed in the world (copies)

- (NSDictionary *)plist;
+ (PDShape *)shapeFromPlist:(NSDictionary *)d;   // groups recombine their members (slow: off the main thread)

// Library parts: shapes made from parameters (PDParts.c), kind "part". Types in palette order: bolt, nut,
// threadedHole, screwHole, edgeHole, roundedBox, roundedCylinder, gear.
+ (NSArray *)partTypes;
+ (NSString *)titleForPartType:(NSString *)type;
+ (BOOL)partTypeIsHole:(NSString *)type;              // made as holes (threaded hole, screw hole, rounded hole)
// [{key, title, kind: "number"|"choice"|"switch", min, max, step, unit, choices: [..]}, …]
+ (NSArray *)parameterSpecForPartType:(NSString *)type;
+ (NSDictionary *)defaultParametersForPartType:(NSString *)type;   // the last ones used, or the stock ones
+ (void)rememberParameters:(NSDictionary *)p forPartType:(NSString *)type;
+ (NSString *)describePart:(NSString *)type parameters:(NSDictionary *)p;   // "M5 × 20 socket head bolt"
// A new part standing on the plate, its footprint centred at (x, y). Nil if the parameters make nothing. Any thread.
+ (PDShape *)partOfType:(NSString *)type parameters:(NSDictionary *)p x:(float)x y:(float)y;
@property (nonatomic, readonly, copy) NSString *partType;
@property (nonatomic, readonly, copy) NSDictionary *parameters;
// The same part made with new parameters, standing where this one stands (same centre, bottom and turn).
- (PDShape *)withParameters:(NSDictionary *)p;

// Shape options for basic shapes (box, cylinder, cone, tube, pyramid, sphere, dome, torus): fillets and chamfers,
// sides, wall thickness, smoothness. Edited with the part editor under the type "shape.<kind>" (the methods
// above take those types too). The mesh is made in mm at the shape's size, so a 3 mm fillet stays 3 mm when
// the shape is resized (setSizeFromOptions). Roof and wedge have none.
+ (BOOL)kindHasOptions:(NSString *)kind;
@property (nonatomic, readonly, copy) NSDictionary *options;   // nil: the plain primitive
- (NSDictionary *)editableOptions;               // the options, or the stock ones for a plain shape
// The same shape made with these options at its present size (a torus also takes the tube as its height).
// Nil if they make nothing.
- (PDShape *)withOptions:(NSDictionary *)o;
// After a resize: remake the mesh at the new size so edge sizes stay in mm. NO if it couldn't be made.
- (BOOL)remakeOptionsMesh;

// Imported models (kind "mesh"): triangles in mm, kept once in Designs/Meshes and shared by every copy.
// Nil with *error set when the mesh is empty or can't be stored. Any thread.
+ (PDShape *)shapeFromTriangles:(const float *)tris count:(int)count name:(NSString *)name x:(float)x y:(float)y error:(NSString **)error;
// Reads an STL (binary or ASCII) or OBJ file into a mesh shape. Any thread.
+ (PDShape *)shapeFromModelFile:(NSString *)path x:(float)x y:(float)y error:(NSString **)error;
@property (nonatomic, readonly, copy) NSString *meshName;
// This shape's world mesh as a binary STL (for the library). NO on failure.
- (BOOL)writeSTL:(NSString *)path;
@end

// The Library's stored models: STL/OBJ files saved from designs (Documents/PrintDeck/Library) and the models
// on the iPad for slicing (Documents/PrintDeck).
@interface PDLibrary : NSObject
+ (NSString *)directory;                         // Documents/PrintDeck/Library
+ (NSArray *)savedParts;                         // paths, newest first
+ (NSArray *)models;                             // paths of STL/OBJ files in Documents/PrintDeck, newest first
+ (NSString *)unusedPathFor:(NSString *)name;    // Library/<name>.stl, numbered if taken
@end

@interface PDDesign : NSObject
+ (NSString *)directory;                         // Documents/PrintDeck/Designs
+ (NSArray *)savedNames;                         // newest first
+ (PDDesign *)loadNamed:(NSString *)name;        // any thread (groups recombine)
+ (BOOL)deleteNamed:(NSString *)name;
+ (NSString *)unusedName:(NSString *)base;       // "Design 3"
+ (BOOL)renameDesign:(NSString *)from to:(NSString *)to;

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSArray *shapes;     // PDShape, back to front in drawing order
- (BOOL)save;
// The solid shapes as one binary STL ("<name> (design).stl" with the user's models): their union, so the slicer
// gets one closed mesh. Ungrouped holes cut nothing (group them with what they should cut) and are counted in
// *looseHoles. Returns the path, or nil with *error set. Any thread.
- (NSString *)exportSTL:(NSString **)error looseHoles:(int *)looseHoles;
@end
