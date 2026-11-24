#import "PDViews.h"

// Dashboard card: the G-code files stored on the printer (newest first) beside a small rotatable 3D preview
// of the selected one. Tapping a file selects it and loads its toolpath through the "files" loader slot
// (streamed from the printer and parsed; only the last selected file stays cached, so it reappears instantly
// after a relaunch). Print starts the selected file after a confirmation.
extern NSString *const PDFilesSelectionNotification;   // the selected file changed (card or detail page)

@interface PDFilesCard : PDCard
// The selected file, shared with the full-screen File page; remembered per printer address.
+ (NSString *)selectedPath;
+ (void)setSelectedPath:(NSString *)path;
+ (void)loadSelected;   // fetch/parse it through the "files" loader slot (cached when possible)
@property (nonatomic, copy) void (^openDetail)(void);   // the Inspect button: open the File page
@property (nonatomic, copy) void (^openSlice)(void);    // the Slice… button: open the Slice page
- (void)refresh;   // printer status changed (enables/disables Print)
@end
