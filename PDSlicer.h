#import <Foundation/Foundation.h>
#import <GLKit/GLKMath.h>
@class PDToolpath;

// On-device slicing for the Centauri Carbon (0.6 mm nozzle, 256 × 256 × 256 mm).
//
//  PDSliceSettings  the user's slicing settings (material, quality, walls/infill, support, adhesion, speeds,
//                   cooling, retraction, advanced), described by a table the Slice page renders, kept in
//                   NSUserDefaults and turned into a CuraEngine config.
//  PDModel          an STL (binary or ASCII) or a built-in test shape, with a placement transform (quarter
//                   turns about X/Y, any angle about Z, uniform scale) that the preview and the slice share.
//  PDSlicer         runs CuraEngine (bundled in PrintDeck.app as a helper executable) on the transformed model,
//                   wraps its G-code in ElegooSlicer-style metadata so the printer lists layers/time/weight,
//                   parses the result for the 3D preview, and uploads it to the printer (optionally printing).
//
// Everything posts PDSlicerNotification on the main thread when its state changes.

extern NSString *const PDSlicerNotification;
extern NSString *const PDSliceSettingsChangedNotification;

#define PD_BED_MM 256.0f

#pragma mark - Settings

// Row descriptors (NSDictionary): key, title, kind ("choice" | "number" | "slider" | "switch"), and
//   choice: options (titles), values (NSNumbers / NSStrings)
//   number / slider: min, max, step, unit, decimals
//   any: hint (one line shown under the title), when (key that must be on/non-zero for the row to apply),
//        advanced (shown only with the Advanced switch on)
@interface PDSliceSettings : NSObject
+ (NSArray *)sections;                       // [{title, editor, tab, rows: [row, …]}, …]
+ (NSArray *)tabsForEditor:(NSString *)editor;                 // "printer" | "filament" | "process"
+ (NSArray *)sectionsForEditor:(NSString *)editor tab:(NSString *)tab advanced:(BOOL)advanced;
+ (NSString *)editorForKey:(NSString *)key;
+ (NSArray *)keysForEditor:(NSString *)editor;
+ (NSDictionary *)defaults;
+ (id)valueForKey:(NSString *)key;
+ (double)numberForKey:(NSString *)key;
+ (void)setValue:(id)value forKey:(NSString *)key;   // posts PDSliceSettingsChangedNotification
+ (void)resetToDefaults;
+ (NSDictionary *)current;                   // defaults overlaid with the user's values
+ (NSDictionary *)rowForKey:(NSString *)key;
+ (NSString *)displayValueForRow:(NSDictionary *)row;   // "0.24 mm", "15 %", "PLA"
@end

#pragma mark - Profiles

// Stock profiles: ElegooSlicer's factory printer / quality / filament profiles for the Centauri Carbon (every
// nozzle), bundled as StockProfiles.plist by tools/make-profiles.py (already translated into the keys above).
// My presets: complete settings the user saved, each tied to the printer (machine + nozzle) it was made for.
// Applying any of them overwrites the settings it covers and posts PDSliceSettingsChangedNotification.
// Profile dictionaries: name, title, settings, and printers (stock quality/filament) or printer (presets).
@interface PDSliceProfiles : NSObject
+ (NSDictionary *)stock;                     // source, commit, date, printers, processes, filaments
+ (NSArray *)printers;
+ (NSDictionary *)currentPrinter;            // the stock printer matching the current nozzle
+ (NSArray *)processesForPrinter:(NSString *)printer;
+ (NSArray *)filamentsForPrinter:(NSString *)printer;
+ (void)applyPrinter:(NSDictionary *)printer;   // machine + its default process; keeps the filament if it fits
+ (void)applyProcess:(NSDictionary *)process;
+ (void)applyFilament:(NSDictionary *)filament;
// User presets, per editor ("printer" | "filament" | "process"); filament/process ones are per printer.
+ (NSArray *)userPresetsForEditor:(NSString *)editor;
+ (void)saveUserPreset:(NSString *)name editor:(NSString *)editor;   // that editor's current settings (same name replaces)
+ (void)applyUserPreset:(NSDictionary *)preset;
+ (void)deleteUserPreset:(NSDictionary *)preset;
+ (void)resetToDefaults;                     // stock Centauri Carbon 0.6 nozzle, 0.24mm Optimal, Elegoo PLA
+ (NSDictionary *)state;
+ (NSString *)selectedTitleForEditor:(NSString *)editor;   // what the editor's combo shows
+ (BOOL)isEdited:(NSString *)editor;         // changed by hand since the preset was picked ("*" / modified)
+ (BOOL)isUser:(NSString *)editor;
+ (NSString *)summary;                       // "0.24mm Optimal · Elegoo PLA*"
@end

#pragma mark - Model

@interface PDModel : NSObject
+ (NSArray *)builtinNames;                   // test shapes made in code
+ (PDModel *)builtin:(NSString *)name;
+ (PDModel *)loadFile:(NSString *)file error:(NSString **)error;   // .stl, binary or ASCII; any thread
@property (nonatomic, readonly, copy) NSString *name;   // file name without extension, or the shape's name
@property (nonatomic, readonly, copy) NSString *source; // file path, or "builtin:<name>"
@property (nonatomic, readonly) NSUInteger triangleCount;
@property (nonatomic, readonly) const float *triangles; // 9 floats (3 vertices) per triangle, model units (mm)
// Placement. The transform is R = Rz(rotZ) · Ry(90°·quarterY) · Rx(90°·quarterX), scaled by `scale`;
// the result is then centred on the bed and dropped to z = 0.
@property (nonatomic) int quarterX, quarterY;
@property (nonatomic) float rotZ, scale;
- (GLKMatrix3)matrix;                        // scale · R
- (GLKVector3)size;                          // transformed bounding-box size, mm
- (GLKVector3)minCorner;                     // transformed bounding-box minimum (before placing)
- (BOOL)writeSTL:(NSString *)file;           // transformed and placed (x/y centred on 0, min z = 0), binary STL
- (NSString *)signature;                     // changes whenever the model or its placement does
@end

#pragma mark - Slicer

typedef enum { PDSliceIdle, PDSliceRunning, PDSliceDone, PDSliceFailed } PDSliceState;
typedef enum { PDUploadIdle, PDUploadRunning, PDUploadDone, PDUploadFailed } PDUploadState;

@interface PDSlicer : NSObject
+ (PDSlicer *)shared;
+ (NSString *)libraryDirectory;              // /var/mobile/Documents/PrintDeck: STL files (copied in, or via "Open in")
+ (NSString *)engineVersion;

@property (nonatomic, strong) PDModel *model;    // the model on the Slice page (kept while the app runs)

// Slicing
@property (nonatomic, readonly) PDSliceState state;
@property (nonatomic, readonly) double progress;         // 0..1
@property (nonatomic, readonly, copy) NSString *phase;   // "Walls 45/166"
@property (nonatomic, readonly, copy) NSString *error;
- (void)slice;                               // slices `model` with the current settings
- (void)cancel;
// The last finished slice
@property (nonatomic, readonly, copy) NSString *resultFile;       // local G-code
@property (nonatomic, readonly, copy) NSString *resultName;       // file name on the printer
@property (nonatomic, readonly, copy) NSString *resultSignature;  // model + settings it was made from
@property (nonatomic, readonly) int resultLayers;
@property (nonatomic, readonly) double resultSeconds, resultFilamentMM, resultGrams, resultSliceTime;
@property (nonatomic, readonly, strong) PDToolpath *resultToolpath;   // for the preview
- (NSString *)currentSignature;              // compare with resultSignature: is the result stale?

// Uploading the result to the printer (SDCP HTTP upload, port 3030)
@property (nonatomic, readonly) PDUploadState uploadState;
@property (nonatomic, readonly) double uploadProgress;
@property (nonatomic, readonly, copy) NSString *uploadError, *uploadedName;
- (void)uploadAndPrint:(BOOL)print;
@end
