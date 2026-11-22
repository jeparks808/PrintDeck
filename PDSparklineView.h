#import <UIKit/UIKit.h>

// Smooth, time-compressed line graph, ported from DeskDash's DDSparklineView. One or more lines placed on a
// compressed time axis (four equal quarters holding, right to left, the last 1, 2, 4 and 8 units of time, so
// recent data is wide and older data squeezed), scrolled between updates at ~20 fps from a timeline the view is
// given, with the value scale easing to new heights instead of jumping.
//
// Feed it a timeline ({window, quarters, grid, t, raw}) and drive `displayTime` from a PDGraphClock each frame.
// For temperatures set `autoRange` so the scale tracks both the low and high of the data (an idle nozzle sits at
// ~25°, so a 0-based scale would flatten it); `minSpan` keeps a steady reading from being blown up into noise.
@interface PDSparklineView : UIView
@property (nonatomic, copy) NSArray *values;         // static fallback (no timeline)
@property (nonatomic, strong) UIColor *color;
@property (nonatomic, assign) CGFloat maxValue;      // 0 = auto
@property (nonatomic, assign) CGFloat minValue;      // bottom of the scale when not auto-ranging (default 0)
@property (nonatomic, assign) BOOL autoRange;        // ease both ends of the scale to the data (temperatures)
@property (nonatomic, assign) CGFloat minSpan;       // smallest top-minus-bottom while auto-ranging (default 0)
@property (nonatomic, assign) NSInteger gridLines;   // dim horizontal guides (detail views)
@property (nonatomic, copy) NSArray *lineColors;     // one per line in the timeline's raw
@property (nonatomic, assign) CGFloat fillAlpha;     // under each line (default 0.07)
@property (nonatomic, assign) BOOL timeGrid;         // vertical time grid (default YES)
- (void)setTimeline:(NSDictionary *)timeline;        // {window, quarters, grid, t, raw}; nil = none
@property (nonatomic, readonly) double timelineT;    // time of the newest sample, 0 = no timeline
@property (nonatomic, assign) double displayTime;    // set per frame from a PDGraphClock
@property (nonatomic, readonly) CGFloat shownMin, shownMax;  // the scale as currently drawn (for a detail axis)
@end

// One display clock for a set of smooth graphs. Samples carry a time ("t"); the clock runs a little behind the
// newest so it has arrived before the display reaches it, and is moved every frame from the iPad's own clock.
@interface PDGraphClock : NSObject
@property (nonatomic, readonly) double displayTime;  // 0 until the first sample
- (void)noteNewest:(double)t;  // after new samples: the newest sample's time
- (BOOL)advance;               // once a frame; NO when nothing moved
@end
