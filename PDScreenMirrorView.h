#import <UIKit/UIKit.h>

// The printer's own touchscreen, live, and pressable: COSMOS only, through PrintDeck's small mirror service on the
// printer (tools/screen-mirror, port 8091). Frames are long-polled as PNG (the service answers when the screen
// changes, so an idle screen costs nothing); touches are sent back as down / move / up in screen pixels.
@interface PDScreenMirrorView : UIView
@property (nonatomic, copy) NSString *host;   // set to nil to stop
@property (nonatomic, readonly) BOOL available;   // the service answered
+ (int)port;
@end
