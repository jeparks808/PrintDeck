#import <UIKit/UIKit.h>

// Full-screen detail page for one temperature card (nozzle / bed / chamber), in the style of DeskDash's detail
// pages: a ‹ back button top-left and a swipe to the right both call backHandler. It shows the big reading, a
// large smooth graph with an eased value axis, min/max/avg over the window, and — for the heated nozzle and bed —
// quick temperature presets. The controller feeds it a timeline and a per-frame displayTime; it refreshes its own
// text from PDPrinter.
@interface PDDetailView : UIView
@property (nonatomic, copy, readonly) NSString *kind;   // "nozzle" / "bed" / "chamber"
@property (nonatomic, copy) void (^backHandler)(void);
@property (nonatomic, copy) void (^openMeshHandler)(void);  // the "Bed mesh" button (bed page only)
- (id)initWithKind:(NSString *)kind;
- (void)setTimeline:(NSDictionary *)timeline;  // per-second samples for the graph
@property (nonatomic, assign) double displayTime;
- (void)refresh;                                // pull current reading/target/stats from PDPrinter
@end
