#import <UIKit/UIKit.h>

@interface PDMainViewController : UIViewController
@property (nonatomic, assign) BOOL cameraEnabled;
- (void)startSearch;
- (void)appDidResignActive;
- (void)appDidBecomeActive;
- (void)showTestEvent:(NSString *)kind;
- (void)openDetailKind:(NSString *)kind;  // "nozzle" / "bed" / "chamber"
- (void)openMesh;                         // the bed-mesh 3D page
- (void)openCardPageKind:(NSString *)kind; // "camera"/"job"/"fans"/"speed"/"machine"
- (void)openSlice:(NSString *)source;
- (void)scrollSliceSettingsTo:(NSString *)section;   // developer aid      // the Slice page; source: an STL path or "builtin:<name>" (nil: keep the current model)
- (void)openDesign:(NSString *)name;      // the 3D design page; name: a saved design (nil: the last one)
@end
