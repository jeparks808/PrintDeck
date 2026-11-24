#import <UIKit/UIKit.h>

// Full-screen Slice page: pick a model (built-in test shapes, or STL files in /var/mobile/Documents/PrintDeck, e.g.
// sent with "Open in PrintDeck"), place it (rotate, lay on a side, scale), edit the slicing settings, slice on the iPad
// with the bundled CuraEngine, preview the toolpath layer by layer, and upload the G-code to the printer
// (optionally starting the print). ‹ PrintDeck or a swipe right goes back; a slice keeps running meanwhile.
@interface PDSlicePage : UIView
@property (nonatomic, copy) void (^backHandler)(void);
- (id)init;
// Open a model file (an STL just received through "Open in…", say) or "builtin:<name>".
- (void)openModelSource:(NSString *)source;
- (void)scrollToSettingsSection:(NSString *)title;   // e.g. "Retraction" (developer aid)
@end
