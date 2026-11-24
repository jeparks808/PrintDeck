#import <UIKit/UIKit.h>
#import <GLKit/GLKit.h>

// The Design page's 3D workplane (OpenGL ES 2.0): the Centauri's plate with a 10 mm grid, the design's shapes
// (solids in their colours, holes as see-through grey) and a box around the selection.
//
// Touch: tap a shape to select it (tap empty space to deselect; with multiSelect on, taps add and remove).
// Drag a shape to slide the selection across the plate, snapped to `snap`. Drag empty space to orbit, two
// fingers to pan, pinch to zoom, double-tap empty space to fit the view.
//
// gizmo 1 (Move) adds red/green/blue arrows to the selection: drag one to move along just that axis (Z too).
// gizmo 2 (Rotate) adds three rings: drag one to turn the selection about that axis, through its centre, in
// 15° steps, or 1° steps with the finger out on the protractor's outer scale (selections resting on the plate
// stay on it). Dragging the shapes themselves still slides them.
//
// gizmo 3 (Scale) works on one selected shape: an arrow with a cube on its end along each of the shape's own
// axes; drag one to stretch the shape along that axis (about its centre, keeping its bottom where it was). With
// uniformScale on, any handle scales all three axes together. Percentages are of the shape's size when it was
// picked in Scale mode (or when Scale mode was entered), 0.1 % to 200 %.
@interface PDDesignView : UIView
@property (nonatomic) NSInteger gizmo;                       // 0 none, 1 move arrows, 2 rotate rings, 3 scale handles
@property (nonatomic) BOOL uniformScale;
@property (nonatomic) float progress;                        // the message's progress bar, 0…1; < 0 hides it (default)
@property (nonatomic, copy) NSArray *shapes;                 // PDShape
@property (nonatomic, copy) NSIndexSet *selection;           // indexes into shapes
@property (nonatomic) BOOL multiSelect;
@property (nonatomic) float snap;                            // mm
@property (nonatomic, copy) NSString *message;               // shown over the view ("Combining shapes…"), nil for none
@property (nonatomic, copy) void (^selectionChanged)(void);
@property (nonatomic, copy) void (^willMove)(void);          // a drag is starting (take an undo snapshot)
@property (nonatomic, copy) void (^moved)(BOOL done);        // shapes moved (done: the drag ended)
- (GLKVector3)focusPoint;                                    // where the view looks, on the plate (new shapes go here)
- (void)fitView;
// Scale mode: the selected shape's size as a percentage of its base size per axis (its own W, D, H), or NO when
// Scale mode isn't on or not exactly one shape is selected.
- (BOOL)scalePercent:(GLKVector3 *)pct;
- (void)resetScaleBase;                                      // the selection's present size becomes 100 %
// Sets one axis's percentage (clamped to 0.1…200 %; all three in proportion with uniformScale). NO if it can't.
- (BOOL)setScalePercent:(float)pct axis:(int)axis;
- (void)redraw;                                              // shapes changed in place
- (void)devDragFrom:(CGPoint)a to:(CGPoint)b hold:(BOOL)hold release:(BOOL)release;   // developer aid: a one-finger drag, view points
@end
