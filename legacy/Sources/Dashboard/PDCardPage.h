#import <UIKit/UIKit.h>

// Full-screen detail page for the non-temperature cards, in the same style as PDDetailView / PDMeshView
// (‹ PrintDeck top-left + swipe-right to go back). One class, switched on `kind`:
//   camera   — a large live camera feed, fps, on/off
//   job      — the current/last job in full (thumbnail, progress, times, speed, controls)
//   fans     — the three fans with live readings and sliders
//   speed    — the print-speed modes with descriptions, and a custom %
//   machine  — camera, jog / home / light, position, status tiles, and the stored files to print
//   file     — the Files card's selected file in detail: big 3D view, slicer details, file list, Print
@interface PDCardPage : UIView
@property (nonatomic, copy, readonly) NSString *kind;
@property (nonatomic, copy) void (^backHandler)(void);
- (id)initWithKind:(NSString *)kind;
// CANVAS page on COSMOS: ask for slot `slot`'s material, then colour, and set it (what a tap on the slot does).
- (void)editLane:(int)slot;
@end
