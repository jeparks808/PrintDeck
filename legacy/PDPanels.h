#import <UIKit/UIKit.h>

// Popover: files stored on the printer; tap one to print it (after a confirmation).
@interface PDFilesViewController : UITableViewController
@property (nonatomic, copy) void (^onDone)(void);
@end

// Popover: move the toolhead / bed and home axes. Only offered while the printer is idle.
@interface PDMoveViewController : UIViewController
@end
