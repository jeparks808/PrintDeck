#import <UIKit/UIKit.h>
@class PDToolpath;

// A rotatable line render of a PDToolpath, in OpenGL ES 2.0 (GLKView), drawn only when something changes
// (a gesture, a new layer), so it costs nothing while idle. The whole path sits in one VBO as GL_LINES of
// int16 vertices (0.01 mm units) and is drawn in up to three ranges: printed layers coloured by height
// (see colorScheme) with a depth cue, the current layer bright, and the layers still to print as a faint ghost.
// Drag to rotate, pinch to zoom, double-tap to reset.
#import "PDToolpath.h"

typedef enum {
	PDToolpathColorFilament,   // the filament's colour, shaded by height (default; falls back to Height without a colour)
	PDToolpathColorLineType,   // OrcaSlicer's line-type colours, shaded by height
	PDToolpathColorHeight      // blue (bed) → orange (top)
} PDToolpathColorScheme;

@interface PDToolpathView : UIView
@property (nonatomic, assign) PDToolpathColorScheme colorScheme;
// Overrides the file's own "; filament_colour" (the Slice page passes the chosen filament colour).
@property (nonatomic, strong) UIColor *filamentColor;
+ (UIColor *)colorForLineType:(PDLineType)t;
+ (NSString *)nameForLineType:(PDLineType)t;
@property (nonatomic, strong) PDToolpath *toolpath;
@property (nonatomic, assign) NSInteger doneLayers;     // layers [0, doneLayers) are drawn as printed
@property (nonatomic, assign) NSInteger currentLayer;   // highlighted layer, -1 for none
@property (nonatomic, copy) void (^interacted)(void);   // the user rotated/zoomed
- (void)resetView;
- (void)redraw;
// Developer aid: spin the model for `secs`, drawing every frame, and report frames per second.
- (void)benchmark:(double)secs done:(void (^)(double fps))done;
@end
