#import <UIKit/UIKit.h>

// Shows an MJPEG (multipart/x-mixed-replace) camera stream. Frames are cut out of the stream by their JPEG
// start/end markers, decoded off the main thread, and dropped while a decode is still running, so the A4
// never falls behind (the Centauri Carbon sends 640x360 at ~10 fps). Reconnects on its own.
@interface PDMJPEGView : UIView
@property (nonatomic, copy) NSURL *url;     // set to nil to stop
@property (nonatomic, readonly) BOOL hasFrame;
@property (nonatomic, readonly) double fps;
- (void)stop;
- (void)start;
@end
