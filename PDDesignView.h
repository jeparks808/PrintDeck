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
@interface PDDesignView : UIView
@property (nonatomic) NSInteger gizmo;                       // 0 none, 1 move arrows, 2 rotate rings
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
- (void)redraw;                                              // shapes changed in place
- (void)devDragFrom:(CGPoint)a to:(CGPoint)b hold:(BOOL)hold release:(BOOL)release;   // developer aid: a one-finger drag, view points
@end
