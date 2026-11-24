#import <UIKit/UIKit.h>

// Shows an MJPEG (multipart/x-mixed-replace) camera stream. Frames are cut out of the stream by their JPEG
// start/end markers, decoded off the main thread, and dropped while a decode is still running, so the A4
// never falls behind (the Centauri Carbon sends 640x360 at ~10 fps). Reconnects on its own.
@interface PDMJPEGView : UIView
@property (nonatomic, copy) NSURL *url;     // set to nil to stop
@property (nonatomic, readonly) BOOL hasFrame;
// Called before every (re)connect; the view opens the stream when `go` runs (e.g. after the printer
// confirms it has switched its camera stream on). Without it the view connects straight away.
@property (nonatomic, copy) void (^prepare)(void (^go)(void));
@property (nonatomic, readonly) double fps;
- (void)stop;
- (void)start;
@end
