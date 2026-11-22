#import <UIKit/UIKit.h>

// Full-screen 3D design page, Tinkercad-style: drop basic shapes (box, cylinder, sphere, …) on the plate, size,
// move and turn them, make some of them holes, and group shapes to merge solids and cut the holes out of them.
// Designs save themselves as you work (Documents/PrintDeck/Designs). Send to slicer exports the solids as one
// STL and opens it on the Slice page. ‹ PrintDeck goes back.
@interface PDDesignPage : UIView
+ (UIImage *)iconImage;                 // the dashboard card's picture
+ (NSArray *)savedDesignNames;          // newest first
@property (nonatomic, copy) void (^backHandler)(void);
@property (nonatomic, copy) void (^sliceHandler)(NSString *stlPath);
- (id)init;
- (void)openDesignNamed:(NSString *)name;
@end
