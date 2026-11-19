#import <UIKit/UIKit.h>

// Filled line graph of NSNumbers. Auto-ranges to the data, so small changes (e.g. 71-74 °F) stay visible.
@interface PDSparklineView : UIView
@property (nonatomic, copy) NSArray *values;
@property (nonatomic, strong) UIColor *color;
@end
