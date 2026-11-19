#import <UIKit/UIKit.h>
#import "PDSparklineView.h"

// Rounded dark card; subclasses lay out inside `contentBounds`.
@interface PDCard : UIControl
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, assign) BOOL tappable;   // highlights on touch, sends UIControlEventTouchUpInside
- (CGRect)contentBounds;
@end

// Temperature: "NOZZLE  215° / 220°" with a heater graph.
@interface PDTempCard : PDCard
@property (nonatomic, strong) UILabel *valueLabel, *targetLabel;
@property (nonatomic, strong) PDSparklineView *graph;
- (void)setCurrent:(NSNumber *)cur target:(NSNumber *)target history:(NSArray *)hist;
@end

// Thick progress bar.
@interface PDProgressBar : UIView
@property (nonatomic, assign) double progress;
@property (nonatomic, strong) UIColor *color;
@end

// Big rounded button with a colored fill.
UIButton *PDButton(NSString *title, UIColor *color);

// Full-screen alert for "finished / paused / failed"; tap anywhere to dismiss.
@interface PDEventOverlay : UIView
+ (void)showInView:(UIView *)view kind:(NSString *)kind title:(NSString *)title detail:(NSString *)detail;
+ (void)dismissInView:(UIView *)view kind:(NSString *)kind; // kind nil = any
@end
