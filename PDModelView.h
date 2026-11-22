#import <UIKit/UIKit.h>
@class PDModel;

// A shaded 3D view of a PDModel on the Centauri's 256 mm bed (OpenGL ES 2.0, GLKView), placed the way the
// slicer will place it: transformed, centred, standing on z = 0. Flat-shaded faces with one light, drawn only
// when something changes. Drag to rotate, pinch to zoom, double-tap to reset. Very large meshes are thinned
// for display (the slicer always gets every triangle).
@interface PDModelView : UIView
@property (nonatomic, strong) PDModel *model;
@property (nonatomic, assign) BOOL warn;              // tint the model red (it doesn't fit)
- (void)modelTransformChanged;                         // placement changed: re-fit and redraw (no re-upload)
- (void)resetView;
- (void)redraw;
@end
