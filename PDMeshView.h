#import <UIKit/UIKit.h>

// Full-screen bed-mesh page: a rotatable 3D height map of the bed on the left, and a panel on the right
// with the deviation, a colour legend and per-corner screw-tram hints. ‹ PrintDeck (top-left) or a swipe
// right (off the 3D canvas) goes back. Drag the model to rotate, pinch to zoom. Pulls the mesh from
// PDMeshSource (helper fetch, a pasted mesh, or the cached/demo one).
@interface PDMeshView : UIView
@property (nonatomic, copy) void (^backHandler)(void);
- (id)init;
@end
