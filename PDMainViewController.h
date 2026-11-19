#import <UIKit/UIKit.h>

@interface PDMainViewController : UIViewController
@property (nonatomic, assign) BOOL cameraEnabled;
- (void)startSearch;
- (void)appDidResignActive;
- (void)appDidBecomeActive;
- (void)showTestEvent:(NSString *)kind;
@end
